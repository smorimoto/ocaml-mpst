open Mpst_implicit.Util
open Session
open Global
   
let a = {role=`A; lens=Fst}
let b = {role=`B; lens=Next Fst}
let c = {role=`C; lens=Next (Next Fst)}
let lv = Lazy.from_val
      
let finish = lv (Cons(lv @@ Prot Close,
             lv @@ Cons(lv @@ Prot Close,
             lv @@ Cons(lv @@ Prot Close, lv Nil))))

let (>>=) = Lwt.(>>=)

(* A global protocol between A, B, and C *)
let create_g () =
    (c --> a) msg @@
    choicemany_at a left_or_right
      (a, (a -->> b) left @@
          (b >>-- c) right @@
          (b >>-- a) msg @@
          finish)
      (a, (a -->> b) right @@
          (b >>-- a) msg @@
          (b >>-- c) left @@
          (c --> a) msg @@
          finish)

(* participant A *)
let t1 s : unit Lwt.t =
  let open Lwt in
  receive `C s >>= fun (`msg(x, s)) -> begin
      Printf.printf "received: %d\n" x;
      if x = 0 then begin
          let s = multicast `B (fun x->x#left) (fun _ -> ()) s in
          gather `B s >>= fun (`msg(str,s)) ->
          str |> List.iter (Printf.printf "A) B says: %s\n");
          close s;
          return ()
        end else begin
          let s = multicast `B (fun x->x#right) (fun _ -> ()) s in
          gather `B s >>= fun (`msg(xs,s)) ->
          List.iteri (fun i x -> Printf.printf "A) B(%d) says: %d\n" i x) xs;
          receive `C s >>= fun (`msg(str,s)) ->
          Printf.printf "C says: %s\n" str;
          close s;
          return ()
        end;
    end >>= fun () ->
  print_endline "A finished.";
  return ()

(* participant B *)
let t2 i s : unit Lwt.t =
  receive `A s >>= begin
      function
      | `left(_,s) ->
         Printf.printf "B(%d): left.\n" i;
         let s = send `C (fun x->x#right) () s in
         let s = send `A (fun x->x#msg) (Printf.sprintf "Hooray! %d" i) s in
         close s;
         Lwt.return ()
      | `right(_,s) ->
         Printf.printf "B(%d): right.\n" i;
         let s = send `A (fun x->x#msg) (1234 * (i+1)) s in
         let s = send `C (fun x->x#left) () s in
         close s;
         Lwt.return ()
    end >>= fun () ->
  Printf.printf "B(%d) finished.\n" i;
  Lwt.return ()


(* participant C *)
let t3 s : unit Lwt.t =
  let open Lwt in
  print_endline "C: enter a number (positive or zero or negative):";
  Lwt_io.read_line Lwt_io.stdin >>= fun line ->
  let num = int_of_string line in
  let s = send `A (fun x->x#msg) num s in
  gather `B s >>= begin
      function
      | `left(_,s) -> begin
          let s = send `A (fun x->x#msg) "Hello, A!" s in
          close s;
          return ()
        end
      | `right(_,s) -> begin
          close s;
          return ()
        end
    end >>= fun () ->
  print_endline "C finished.";
  return ()

let () =
  let pa, pb, pc =
    let g = create_g () in
    get_sess a g, get_sess b g, get_sess c g
  in
  let [b_conns; [c_conn]] =
    forkmany_groups [
        {groupname="B";count=5;groupbody=(fun i [[a_conn];[c_conn]] ->
           Lwt_main.run (t2 i (pb |> add_conn `A a_conn |> add_conn `C c_conn)))};
        {groupname="C";count=1;groupbody=(fun _ [[a_conn];b_conns] ->
           Lwt_main.run (t3 (pc |> add_conn `A a_conn |> add_conn_many `B b_conns)))}] in
  Lwt_main.run (t1 (pa |> add_conn_many `B b_conns |> add_conn `C c_conn))
