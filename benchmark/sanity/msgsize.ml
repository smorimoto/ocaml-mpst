let (>>=) = Lwt.(>>=)

module Bench(S:Mpst_base.S.SESSION)(G:Mpst_base.S.GLOBAL with module Session = S)(U:Mpst_base.S.UTIL with module Global = G) = struct
  open G
  open U

  let a = {role=`A; lens=Fst}
  let b = {role=`B; lens=Next Fst}

  let finish = one @@ one @@ nil

  let mkglobal () =
    let rec g =
      lazy begin
          (b --> a) msg @@
            choice_at a left_or_right
              (a, (a --> b) left @@
                    finish)
              (a, (a --> b) right @@
                    loop g)
        end
    in
    Lazy.force g

  open S
  let tA cnt s =
    let rec loop i s =
      receive `B s >>= fun (`msg((),s)) ->
      if i > 0 then begin
          let s = send `B (fun x->x#left) () s in
          close s;
          Lwt.return ()
        end else begin
          let s = send `B (fun x->x#right) () s in
          loop (i-1) s
        end
    in
    loop cnt s

  let tB s =
    let rec loop s =
      let s = send `A (fun x->x#msg) () s in
      receive `A s >>= function
      | `left((),s) ->
         close s;
         Lwt.return ()
      | `right((),s) ->
         loop s
    in
    loop s

end

module Bench_shmem = Bench(Mpst_shmem.Session)(Mpst_shmem.Global)(Mpst_shmem.Util)
module Bench_implicit = Bench(Mpst_implicit.Session)(Mpst_implicit.Global)(Mpst_implicit.Util)

let count = 10000

let run_shmem () =
  let open Bench_shmem in
  let open Mpst_shmem.Global in
  let g = mkglobal () in
  let sa = get_sess a g in
  let sb = get_sess b g in
  Lwt_main.run (Lwt.join [tA count sa; tB sb])

let run_implicit () =
  let open Bench_implicit in
  let open Mpst_implicit.Global in
  let g = mkglobal () in
  let sa = get_sess a g in
  let sb = get_sess b g in
  let open Mpst_implicit.Forkpipe in
  let [b_conn] =
    forkmany [{procname="B";procbody=(fun [a_conn] ->
                               Lwt_main.run @@ tB (sb |> add_conn `A a_conn)
                             )}]
  in
  Lwt_main.run @@ tA count (sa |> add_conn `B b_conn);
  b_conn.close ()
                            
  
(* https://blog.janestreet.com/core_bench-micro-benchmarking-for-ocaml/ *)
let () =
  let open Core in
  let open Core_bench in
  Command.run
    (Bench.make_command [
         Bench.Test.create ~name:"shmem" run_shmem;
         Bench.Test.create ~name:"implicit" run_implicit;
    ])
