(*
©  Clément Joly, 2016-2017

leo@wzukw.eu.org

This software is a computer program whose purpose is to use Pomodoro method.

This software is governed by the CeCILL-B license under French law and
abiding by the rules of distribution of free software.  You can  use,
modify and/ or redistribute the software under the terms of the CeCILL-B
license as circulated by CEA, CNRS and INRIA at the following URL
"http://www.cecill.info".

As a counterpart to the access to the source code and  rights to copy,
modify and redistribute granted by the license, users are provided only
with a limited warranty  and the software's author,  the holder of the
economic rights,  and the successive licensors  have only  limited
liability.

In this respect, the user's attention is drawn to the risks associated
with loading,  using,  modifying and/or developing or reproducing the
software by the user in light of its specific status of free software,
that may mean  that it is complicated to manipulate,  and  that  also
therefore means  that it is reserved for developers  and  experienced
professionals having in-depth computer knowledge. Users are therefore
encouraged to load and test the software's suitability as regards their
requirements in conditions enabling the security of their systems and/or
data to be ensured and,  more generally, to use and operate it in the
same conditions as regards security.

The fact that you are presently reading this means that you have had
knowledge of the CeCILL-B license and that you accept its terms.

*)

open Core.Std;;

module T = Time;;
module Ts = Time.Span;;

(* Task plumbery *)

(* Some type to describe states of ptasks *)
type status = Active | Done;;
(* Type of timer *)
type of_timer =
    Pomodoro | Short_break | Long_break
;;

(* Create a timer of duration (in minute). The on_exit function is called the
 * first time the timer is finished *)
class timer duration of_type ~on_finish name running_meanwhile running_when_done =
  let run_meanwhile () =
    Lwt_process.shell running_meanwhile
    |> Lwt_process.open_process_none
  in
  object(s)
    val name : string = name
    method name = name
    val duration = Ts.of_min duration
    val start_time = T.now ()
    val mutable marked_finished = false

    val of_type : of_timer = of_type
    method of_type = of_type

    method private call_on_finish_once =
      if not marked_finished
      then begin
        on_finish s;
        marked_finished <- true
      end

    method remaining =
      let now = T.now () in
      let eleapsed_time = T.diff now start_time in
      let remaining_time = Ts.(duration - eleapsed_time) in
      if Ts.(eleapsed_time < duration)
      then Some remaining_time (* Time remaining *)
      else begin
        s#call_on_finish_once;
        None
      end
    method is_finished = Option.is_none s#remaining
    method cancel =
      if not marked_finished then marked_finished <- true

    (* Command running as long as the timer is not finished, launched at
     * instanciation *)
    val mutable running_meanwhile = run_meanwhile ()
    (* Stop and keep running when necessary *)
    method update_running_meanwhile =
      let make_sure_its_running () =
        running_meanwhile#state
        |> function | Lwt_process.Running -> ()
                    | Lwt_process.Exited _ -> running_meanwhile <- run_meanwhile ()
      in
      if s#is_finished
      then running_meanwhile#terminate
      else make_sure_its_running ()

    (* Command to run when finish *)
    val running_when_done = running_when_done
    method run_done =
      Lwt_process.shell running_when_done
      |> Lwt_process.exec ~timeout:4. (* TODO Configure it *)
      |> ignore
  end

(* TODO Create a special object for timer that are elleapsed and that do nothing *)
let empty_timer () =
  new timer 0. Short_break ~on_finish:(fun _ -> ()) "Empty" "" ""
  |> Option.some
;;

(* A task (written ptask to avoid conflict with lwt), like "Learn OCaml". Cycle
 * sets the number and order of timers *)
class ptask
    ?num (* Position in log file, useful to order tasks *)
    ~name
    ~description
    ?done_at
    ?number_of_pomodoro
    ?estimation
    ?interruption
    cycle
    (simple_timer:(of_timer -> timer))
  =
  let cycle_length = List.length cycle in
  object(s:'s)
    val name : string Avl.t = new Avl.t name
    val description : string Avl.t = new Avl.t description
    method name = name
    method description = description
    (* Way to identify a task uniquely, XXX based on its name for now *)
    method id = String.hash s#name#get

    val status =
      new Avl.t (match done_at with Some _ -> Done | None -> Active)
    val done_at = new Avl.t done_at
    method done_at = done_at
    method mark_done =
      done_at#set T.(now () |> to_string |> Option.some);
      status#set Done
    method status = status
    method is_done =
      status#get = Done

    val num : int option Avl.t = new Avl.t num
    method num = num

    val cycle : of_timer list Avl.t = new Avl.t cycle
    val cycle_length = cycle_length
    (* Position in the cycle, lead to problem if cycle is empty *)
    val mutable position = -1
    val mutable current_timer = None
    val number_of_pomodoro : int option Avl.t = new Avl.t number_of_pomodoro

    val interruption : int option Avl.t = new Avl.t interruption
    method interruption = interruption
    method record_interruption =
      interruption#set
        (Some (Option.value_map ~default:(0+1) ~f:succ interruption#get));
      Option.iter current_timer ~f:(fun ct -> ct#cancel);

    val estimation : int option Avl.t = new Avl.t estimation
    method estimation = estimation

    method number_of_pomodoro = number_of_pomodoro
    (* Return current timer. Cycles through timers, as one finishes *)
    method current_timer () =
      let is_some_finished =
        Option.value_map ~default:false
          ~f:(fun ct -> ct#is_finished)
      in
      if
        status#get = Active
        && is_some_finished current_timer
      then begin
        let ct = Option.value_exn current_timer in
        if ct#of_type = Pomodoro
        then
          number_of_pomodoro#set
            (Option.value ~default:0 number_of_pomodoro#get
             |> (fun nop -> nop + 1)
             |> Option.some);
        (* Circle through positions *)
        position <- (position + 1) mod cycle_length;
        current_timer <- Some (simple_timer (List.nth_exn cycle#get position));
      end
      ;
      current_timer
    (* To interrupt a task *)
    method remove_timer = current_timer <- None
    (* Attach a timer to a task *)
    method attach_timer =
      if Option.is_none current_timer
      then begin
        status#set Active;
        current_timer <- empty_timer ()
      end

    (* Returns a summary of the task, short or with more details *)
    method private summary ~long =
      let short_summary = sprintf "%s: \"%s\""
          (name#print_both String.of_string)
          (description#print_both String.of_string)
      in
      let done_at =
        done_at#print_both (Option.value_map~default:"(no done date)"
          ~f: (fun date -> sprintf "(done at %s)" date))
      in
      let nb =
        sprintf "with %s pomodoro" (number_of_pomodoro#print_both
          (Option.value_map ~f:Int.to_string ~default:"0"))
      in
      let interruption =
        sprintf "interrruption: %s"
          (interruption#print_both
            (Option.value_map ~default:"0" ~f:Int.to_string))
      in
      let estimation =
        sprintf "estimation: %s"
          (estimation#print_both
            (Option.value_map ~default:"0" ~f:Int.to_string))
      in
      (* Display only what is needed *)
      Option.[
        Some short_summary
      ; (some_if long done_at)
      ; (some_if long nb)
      ; (some_if long interruption)
      ; (some_if long estimation)
      ] |> List.filter_map ~f:(fun a -> a)
      |> String.concat ~sep:", "
    method short_summary = s#summary ~long:false
    method long_summary = s#summary ~long:true


    (* Update a task with data of an other, provided they have the same ids.
     * Keeps timer running, since they are kept as-is. Updates states when it
     * makes sens *)
    method update_with (another:'s) =
      let update_actual avl =
        avl#turn2log;
        avl
      in
      let clever_status_update =
        match status#get, another#status#get with
        | Done, Active -> status#update_log another#status#get
        | Active, Done | Done, Done | Active, Active ->
          (* Make sure current state is the log one *)
          status#update_log another#status#get |> update_actual
      in
      assert (another#id = s#id);
      {<
        status = clever_status_update;
        name = name#update_log another#name#get |> update_actual;
        description = description#update_log another#description#get |> update_actual;
        num = num#update_log another#num#get |> update_actual;
        number_of_pomodoro = number_of_pomodoro#update_log another#number_of_pomodoro#get;
        done_at = done_at#update_log another#done_at#get;
        interruption = interruption#update_log another#interruption#get;
        estimation = estimation#update_log another#estimation#get;
      >}
  end

(* Pretty printing of remaining time *)
let time_remaining ~timer =
  timer#remaining |> Option.value ~default:(Ts.create ())
  (* XXX Manual pretty printing *)
  |> Ts.to_parts |> fun { Ts.Parts.hr ; min; sec ; _ } ->
  hr |> function
  | 0 -> sprintf "%i:%i" min sec
  | _ -> sprintf "%i:%i:%i" hr min sec
;;

(* Get first ptask not marked as done *)
let rec get_pending = function
  | hd :: tl ->
    if hd#is_done
    then get_pending tl
    else Some hd
  | [] -> None
;;

(* When a timer is finished, notify *)
let on_finish timer =
  sprintf "notify-send '%s ended.'" timer#name
  |> Sys.command
  |> ignore;
  timer#run_done
;;

