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

(* Tools with log file *)

(* A set of arbitrary defaults *)
module Defaults = struct

  let ticking_command = ""
  let ringing_command = ""
  let max_ring_duration = 10.

  let tick = 0.1;;

end;;

(* Simple log of pomodoros & tasks, with settings *)
type sort_of_timer =
  | Pomodoro
  | Short_break
  | Long_break
[@@deriving sexp];;
type timer_sexp = {
  sort : sort_of_timer;
  duration : float;
  ticking_command : string
      [@default Defaults.ticking_command] [@sexp_drop_default];
  ringing_command : string
      [@default Defaults.ringing_command] [@sexp_drop_default];
  max_ring_duration : float
      [@default Defaults.max_ring_duration] [@sexp_drop_default];
} [@@deriving sexp]

(* Defaults from Pomodoro guide *)
let default_cycle () =
  let canonical_duration = function
    | Pomodoro -> 25.
    | Short_break -> 3. (* Between 3 and 5 minutes *)
    | Long_break -> 15. (* Between 15 and 30 minutes *)
  in
  [ Pomodoro ; Short_break
  ; Pomodoro ; Short_break
  ; Pomodoro ; Short_break
  ; Pomodoro ; Long_break ]
  |> List.map ~f:(fun sort_of_timer ->
      { sort = sort_of_timer
      ; duration = canonical_duration sort_of_timer
      ; ticking_command = ""
      ; ringing_command = ""
      ; max_ring_duration = Defaults.max_ring_duration }
    )
;;

type settings_sexp = {
  tick : float [@default Defaults.tick] [@sexp_drop_default];
  timer_cycle : timer_sexp list [@default default_cycle ()]
} [@@deriving sexp]
type task_sexp = {
  name : string;
  description : string sexp_option;
  done_at : string sexp_option; (* date and time iso8601 like 2016-09-10T14:57:25 *)
  done_with : int sexp_option; (* Number of pomodoro used *)
  (* Write down an estimation of the number of needed pomodoro *)
  estimation : int sexp_option;
  short_interruption : int sexp_option; (* Track short interruptions *)
  long_interruption : int sexp_option; (* Track long interruptions *)
  day : Date.t sexp_option (* The day you plan to do the task *)
} [@@deriving sexp]
type log = {
  settings : settings_sexp;
  tasks : task_sexp sexp_list;
} [@@deriving sexp]

(* Internal bundle of relevant content for a read log file *)
type internal_read_log = {
    fname : string; (* Stands for filename *)
    settings : settings_sexp;
    ptasks : Tasks.ptask list;
}

(* Read log containing tasks and settings, tries multiple times since user may
 * edit file and lead to temporal removal *)
let read_log filename =
  let something_went_wrong exn =
    let display_exn =
      "Something went wrong" ::
         (Exn.to_string exn
          |> String.split_lines)
    in
    let map_string_list_to_task =
      List.map ~f:(fun name ->
            {
              name;
              description = Exn.to_string exn |> Option.some;
              done_at = None; done_with = None; estimation = None;
              short_interruption = None; long_interruption = None;
              day = None
            }
        )
    in
    (* A default pseudo log file to show details when we have trubble reading
     * the user supplied log file *)
    {
      settings = { tick = Defaults.tick ; timer_cycle = default_cycle () };
      tasks = display_exn |> map_string_list_to_task
    }
  in
  let log =
    try Sexp.load_sexp_conv_exn filename log_of_sexp
    with exn -> something_went_wrong exn
  in
  {
    fname = filename;
    settings = log.settings;
    ptasks = List.mapi log.tasks
        ~f:(fun task_position (task_sexp:task_sexp) ->
            new Tasks.ptask
              ~num:task_position
              ~name:task_sexp.name
              ?description:task_sexp.description
              ?done_at:task_sexp.done_at
              ?number_of_pomodoro:task_sexp.done_with
              ?estimation:task_sexp.estimation
              ?short_interruption:task_sexp.short_interruption
              ?long_interruption:task_sexp.long_interruption
              ?day:task_sexp.day
          );
  }

(* Update entries, dropping all tasks in old log file if they are not in the new
 * one and adding those in the new log file, even if they were not in the new
 * one. Makes sure we stop timers of task going deeper in the list *)
let reread_log r_log =
  (* Disable timer from tasks other than the first, active, one *)
  let fname = r_log.fname in (* Name is common to both logs *)
  let new_log = (read_log fname) in
  let old_ptasks = r_log.ptasks in
  let new_ptasks = (read_log fname).ptasks in
  let ptasks = (* Merge current state and log file *)
    List.map new_ptasks
      ~f:(fun new_task ->
          List.find_map old_ptasks
            ~f:(fun old_task ->
                if new_task#id = old_task#id
                then Some (old_task#update_with new_task)
                else None
              )
          |> Option.value ~default:new_task
        )
  in
  (* Erase old settings *)
  { fname ; ptasks ; settings = new_log.settings }
;;

module Li = Lwt_inotify;;
class read_log filename =
  let ( >>= ) = Lwt.( >>= ) in
  let inotify =
    Li.create () >>= fun inotify ->
    Li.add_watch inotify filename Inotify.[ S_Modify ]
    >>= fun _ -> Lwt.return inotify
  in
  let new_reader () =
    inotify >>= (fun inotify -> Li.read inotify)
  in
  object(s)
    (* Should not be used directly, only through irl method below *)
    val mutable internal_read_log : internal_read_log = read_log filename
    val mutable reader = new_reader ()

    method private irl =
      Lwt.state reader
      |> (function
          | Lwt.Return _ ->
            reader <- new_reader ();
            internal_read_log <- reread_log internal_read_log;
          | Lwt.Fail exn -> raise exn
          | Lwt.Sleep -> () (* Give result in cache *)
        );
      internal_read_log

    method fname = s#irl.fname;
    method settings = s#irl.settings;
    method ptasks = s#irl.ptasks;
  end
;;

