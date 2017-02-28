(*
 * Copyright (C) 2010 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

(** client-side for remote database access protocol v2 *)

module D = Debug.Make(struct let name="jjd27" end)
open D

open Db_rpc_common_v2
open Db_exn

open Stdext.Threadext

let map = Hashtbl.create 10 (* maps request id to (condvar to wake up, buffer containing response) *)

let allow_concurrent_db_access = true

(* Necessary because initialise is never called... *)
let d_thread_running = ref false

let process_response response f =
  match response with
  | Db_interface.String s -> begin
    match Jsonrpc.of_string s with
    | Rpc.Dict xs ->
      begin
        match List.assoc "id" xs with
        | Rpc.Int id ->
          let contents = List.assoc "contents" xs in
          f id contents
        | _ -> raise (Failure "couldn't find 'id' field")
      end
    | _ ->
      raise (Failure "Expected dict with 'contents' and 'id'")
    end
  | Db_interface.Bigbuf b -> raise (Failure "Response too large - cannot convert bigbuffer to json!")

module Make = functor(RPC: Db_interface.RPC) -> struct
  let rec dispatcher_thread () =
    d_thread_running := true;
    begin
    try
      let response = RPC.recv () in
      process_response response (fun id contents ->
        if Hashtbl.mem map id then
        let (cv, mutex, buf) = Hashtbl.find map id in
        buf := Some contents;
        Mutex.execute mutex (fun () -> Condition.broadcast cv)
      )
    with e ->
      ((*debug "jjd27: suppressing error %s in dispatcher_thread" (Printexc.to_string e)*))
    end;
    dispatcher_thread ()

  (* TODO ideally this is where we would start the dispatcher_thread, but initialise is never called! *)
  let initialise = RPC.initialise

  let rpc x =
    let id = Random.int64 Int64.max_int in
    let request = Jsonrpc.to_string (Rpc.Dict ["contents", x; "id", Rpc.Int id]) in
    if allow_concurrent_db_access then begin
      (* TODO because initialise is never called *)
      if not !d_thread_running then ignore (Thread.create dispatcher_thread ()); (* TODO mutex *)
  
      let buf = ref None in
      let cv = Condition.create () in
      let mutex = Mutex.create () in
      Hashtbl.add map id (cv, mutex, buf);

      Mutex.execute mutex (fun () ->
        RPC.send request;
        Condition.wait cv mutex;
        Hashtbl.remove map id;
        match !buf with
        | Some buf -> buf
        | None -> raise (Failure "woken up but no response")
      )
    end else begin
      let response = RPC.rpc request in
      process_response response (fun id' contents ->
        if id = id' then contents
        else raise (Failure (Printf.sprintf "expected id %Ld, received %Ld" id id')))
    end

  let process (x: Request.t) =
    let y : Response.t = Response.t_of_rpc (rpc (Request.rpc_of_t x)) in
    match y with
    | Response.Dbcache_notfound (x, y, z) ->
      raise (DBCache_NotFound (x,y,z))
    | Response.Duplicate_key_of (w, x, y, z) ->
      raise (Duplicate_key (w,x,y,z))
    | Response.Uniqueness_constraint_violation (x, y, z) ->
      raise (Uniqueness_constraint_violation (x,y,z))
    | Response.Read_missing_uuid (x, y, z) ->
      raise (Read_missing_uuid (x,y,z))
    | Response.Too_many_values (x, y, z) ->
      raise (Too_many_values (x,y,z))
    | y -> y

  let get_table_from_ref _ x =
    match process (Request.Get_table_from_ref x) with
    | Response.Get_table_from_ref y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let is_valid_ref _ x =
    match process (Request.Is_valid_ref x) with
    | Response.Is_valid_ref y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let read_refs _ x =
    match process (Request.Read_refs x) with
    | Response.Read_refs y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let read_field_where _ x =
    match process (Request.Read_field_where x) with
    | Response.Read_field_where y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let db_get_by_uuid _ t u =
    match process (Request.Db_get_by_uuid (t, u)) with
    | Response.Db_get_by_uuid y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let db_get_by_name_label _ t l =
    match process (Request.Db_get_by_name_label (t, l)) with
    | Response.Db_get_by_name_label y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let read_set_ref _ x =
    match process (Request.Read_set_ref x) with
    | Response.Read_set_ref y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let create_row _ x y z =
    match process (Request.Create_row (x, y, z)) with
    | Response.Create_row y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let delete_row _ x y =
    match process (Request.Delete_row (x, y)) with
    | Response.Delete_row y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let write_field _ a b c d =
    match process (Request.Write_field (a, b, c, d)) with
    | Response.Write_field y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let read_field _ x y z =
    match process (Request.Read_field (x, y, z)) with
    | Response.Read_field y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let find_refs_with_filter _ s e =
    match process (Request.Find_refs_with_filter (s, e)) with
    | Response.Find_refs_with_filter y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let read_record _ x y =
    match process (Request.Read_record (x, y)) with
    | Response.Read_record (x, y) -> x, y
    | _ -> raise Remote_db_server_returned_bad_message

  let read_records_where _ x e =
    match process (Request.Read_records_where (x, e)) with
    | Response.Read_records_where y -> y
    | _ -> raise Remote_db_server_returned_bad_message

  let process_structured_field _ a b c d e =
    match process (Request.Process_structured_field(a, b, c, d, e)) with
    | Response.Process_structured_field y -> y
    | _ -> raise Remote_db_server_returned_bad_message
end
