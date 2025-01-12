(* Copyright (C) 2022- Authors of Melange
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)

open Mellib

let extensions =
  Literals.
    [
      suffix_ml;
      suffix_mli;
      suffix_mll;
      suffix_re;
      suffix_rei;
      suffix_res;
      suffix_resi;
    ]

let timer = ref None

let debounce ~f ms =
  match !timer with
  | Some t ->
      Bsb_log.debug "Waiting... next run in %ims@." (Luv.Timer.get_due_in t)
  | None -> (
      let ti = Result.get_ok (Luv.Timer.init ()) in
      timer := Some ti;
      match
        Luv.Timer.start ti ms (fun () ->
            f ();
            timer := None)
      with
      | Ok () -> Bsb_log.debug "Started timer, running in %ims@." ms
      | Error e ->
          Bsb_log.warn "Error starting the timer: %s@." (Luv.Error.strerror e))

module Task = struct
  type info = { fd : Luv.Process.t; paths : string list }
  type t = unit -> info
end

module Job = struct
  type t = {
    mutable fd : Luv.Process.t option;
    mutable watchers : (string, Luv.FS_event.t) Hashtbl.t;
    task : Task.t;
  }

  let create ~task = { task; fd = None; watchers = Hashtbl.create 64 }

  let interrupt t =
    Option.iter
      (fun fd ->
        if Luv.Handle.is_active fd then
          match Luv.Process.kill fd Luv.Signal.sigterm with
          | Ok () -> t.fd <- None
          | Error e ->
              Bsb_log.warn "Error trying to stop program:@\n  %s"
                (Luv.Error.strerror e))
      t.fd

  let restart ?started t =
    debounce 150 ~f:(fun () ->
        let new_task_info =
          match t.fd with
          | None -> t.task ()
          | Some fd ->
              if Luv.Handle.is_active fd then (
                interrupt t;
                t.task ())
              else t.task ()
        in
        Option.iter (fun f -> f new_task_info) started;
        t.fd <- Some new_task_info.fd)

  let stop_watchers t =
    Hashtbl.iter
      (fun _path watcher ->
        let (_ : _ result) = Luv.FS_event.stop watcher in
        ())
      t.watchers

  let stop t =
    interrupt t;
    stop_watchers t
end

(* TODO: bail and exit on errors *)
let rec watch ~(job : Job.t) paths =
  Ext_list.iter paths (fun path ->
      if Hashtbl.mem job.watchers path then ( (* Already being watched *) )
      else
        match Luv.FS_event.init () with
        | Error e ->
            Bsb_log.error "Error starting watcher for %s: %s@." path
              (Luv.Error.strerror e)
        | Ok watcher -> (
            let stat = Luv.File.Sync.stat path in
            match stat with
            | Error e ->
                Bsb_log.error "Error starting watcher for %s: %s@." path
                  (Luv.Error.strerror e)
            | Ok _stat ->
                Hashtbl.replace job.watchers path watcher;
                (* Source_metadata lists all directories, and computes the
                   entire set if `subdirs: true`, so we don't need the
                   recursive flag. *)
                Luv.FS_event.start ~recursive:false ~stat:true watcher path
                  (function
                  | Error e ->
                      Bsb_log.error "Error watching %s: %s@." path
                        (Luv.Error.strerror e);
                      ignore (Luv.FS_event.stop watcher);
                      Luv.Handle.close watcher ignore
                  | Ok (file, _events) ->
                      let file_extension = Filename.extension file in
                      if Ext_list.mem_string extensions file_extension then (
                        let new_watchers = Hashtbl.create 64 in

                        let new_paths =
                          Ext_list.fold_left paths [] (fun acc path ->
                              match Hashtbl.find job.watchers path with
                              | prev_watcher ->
                                  (* Remove existing watchers from the Hashtbl
                                     and add them to the new table *)
                                  Hashtbl.remove job.watchers path;
                                  Hashtbl.replace new_watchers path prev_watcher;
                                  acc
                              | exception Not_found ->
                                  (* New watchers will be added on the recursive call *)
                                  path :: acc)
                        in
                        (* Stop the previous watchers *)
                        Hashtbl.iter
                          (fun _ watcher ->
                            let (_ : _ result) = Luv.FS_event.stop watcher in
                            ())
                          job.watchers;
                        (* Drop the old watchers before creating the new ones *)
                        job.watchers <- new_watchers;

                        Job.restart ~started:(fun _ -> watch ~job new_paths) job))
            ))

let watch ~task paths =
  let job = Job.create ~task in
  watch ~job paths;
  match Luv.Signal.init () with
  | Ok handle -> (
      let handler () =
        prerr_endline "Exiting";
        Job.stop job;
        Luv.Handle.close handle ignore
      in
      match Luv.Signal.start handle Luv.Signal.sigint handler with _ -> ())
  | Error _ -> ()
