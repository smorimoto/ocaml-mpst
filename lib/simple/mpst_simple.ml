module Dyncheck = Dyncheck

module LinMonad = LinMonad

type ('la,'lb,'va,'vb) label =
    {make_obj: 'va -> 'la;
     make_var: 'vb -> 'lb}

type ('lr, 'l, 'r) obj_merge =
    {obj_merge: 'l -> 'r -> 'lr}

type close = Close

let close Close = ()

type _ wrap =
  | WrapSend : (< .. > as 'obj) -> 'obj wrap
  | WrapRecv : ([>] as 'var) Event.event -> 'var Event.event wrap
  | WrapClose : close wrap

let unwrap : type t. t wrap -> t = function
  | WrapSend(obj) -> obj
  | WrapRecv(ev) -> ev
  | WrapClose -> Close

type _ epseq =
  Cons : 'hd wrap * 'tl epseq lazy_t -> ('hd * 'tl) epseq
| Nil : unit epseq

let epseq_head : type hd tl. (hd * tl) epseq lazy_t -> hd wrap =
  fun (lazy (Cons(hd,_))) -> hd

let epseq_tail : type hd tl. (hd * tl) epseq lazy_t -> tl epseq lazy_t = fun xs ->
  lazy begin
      match xs with
      | lazy (Cons(_,lazy tl)) -> tl
    end

type (_,_,_,_) lens =
  | Fst  : ('hd0, 'hd1, ('hd0 * 'tl) epseq, ('hd1 * 'tl) epseq) lens
  | Next : ('a, 'b, 'tl0 epseq, 'tl1 epseq) lens
           -> ('a,'b, ('hd * 'tl0) epseq, ('hd * 'tl1) epseq) lens

let rec get : type a b xs ys. (a, b, xs, ys) lens -> xs lazy_t -> a wrap = fun ln xs ->
  match ln with
  | Fst -> epseq_head xs
  | Next ln' -> get ln' (epseq_tail xs)

let rec put : type a b xs ys. (a,b,xs,ys) lens -> xs lazy_t -> b wrap -> ys lazy_t =
  fun ln xs b ->
  match ln with
  | Fst -> lazy (Cons(b, epseq_tail xs))
  | Next ln' ->
     lazy
       begin match xs with
       | lazy (Cons(a, xs')) -> Cons(a, put ln' xs' b)
       end

type ('robj,'rvar,'c,'a,'b,'xs,'ys) role = {label:('robj,'rvar,'c,'c) label; lens:('a,'b,'xs,'ys) lens}


exception RoleNotEnabled

let merge_wrap : type s. s wrap -> s wrap -> s wrap = fun l r ->
  match l, r with
  | WrapSend _, WrapSend _ -> raise RoleNotEnabled
  | WrapRecv l, WrapRecv r -> WrapRecv (Event.choose [l; r])
  | WrapClose, WrapClose -> WrapClose
  | _, _ -> assert false (* OCaml typechecker cannot check exhaustiveness in this case *)


let rec merge_epseq : type t. t epseq lazy_t -> t epseq lazy_t -> t epseq lazy_t = fun ls rs ->
  lazy begin
      match ls, rs with
      | lazy (Cons(hd_l,tl_l)), lazy (Cons(hd_r, tl_r)) ->
         (Cons(merge_wrap hd_l hd_r, merge_epseq tl_l tl_r))
      | lazy Nil, _ ->
         Nil
    end

let send_obj : 'obj. (< .. > as 'obj) wrap -> 'obj = function[@warning "-8"]
  | WrapSend obj -> obj

let goto l =
  lazy (Lazy.force @@ Lazy.force l)

let a = {label={make_obj=(fun v->object method role_a=v end);
               make_var=(fun v->(`role_a(v):[`role_a of _]))}; (* explicit annotataion is mandatory *)
         lens=Fst}
let b = {label={make_obj=(fun v->object method role_b=v end);
               make_var=(fun v->(`role_b(v):[`role_b of _]))}; (* explicit annotataion is mandatory *)
         lens=Next Fst}
let c = {label={make_obj=(fun v->object method role_c=v end);
               make_var=(fun v->(`role_c(v):[`role_c of _]))}; (* explicit annotataion is mandatory *)
         lens=Next (Next Fst)}
let msg =
  {make_obj=(fun f -> object method msg=f end);
   make_var=(fun v -> `msg(v))}
let left =
  {make_obj=(fun f -> object method left=f end);
   make_var=(fun v -> `left(v))}
let right =
  {make_obj=(fun f -> object method right=f end);
   make_var=(fun v -> `right(v))}
let left_or_right =
  {obj_merge=(fun l r -> object method left=l#left method right=r#right end)}
let to_b m =
  {obj_merge=(fun l r -> object method role_b=m.obj_merge l#role_b r#role_b end)}
let b_or_c =
  {obj_merge=(fun l r -> object method role_b=l#role_b method role_c=r#role_c end)}

(* let finish =
 *   let rec fini = lazy (Cons(Close, fini)) in
 *   Lazy.from_val (Lazy.force fini) *)

let get_ep r g = unwrap (get r.lens g)

let one xs = Lazy.from_val (Cons(WrapClose, xs))
let nil = Lazy.from_val Nil

let finish = one @@ one @@ one @@ nil

module type LIN = sig
  type 'a lin
  val mklin : 'a -> 'a lin
end

let choice_at : 'obj 'obj0 'obj1 'g 'g1 'g00 'g01.
      (_, _, _, close, < .. > as 'obj, 'g1 epseq, 'g epseq) role ->
      ('obj, < .. > as 'obj0, < .. > as 'obj1) obj_merge ->
      (_, _, _, 'obj0, close, 'g00 epseq, 'g1 epseq) role * 'g00 epseq lazy_t ->
      (_, _, _, 'obj1, close, 'g01 epseq, 'g1 epseq) role * 'g01 epseq lazy_t ->
      'g epseq lazy_t
  = fun r merge (r1,g1) (r2,g2) ->
  let e1, e2 = get r1.lens g1, get r2.lens g2 in
  let g1', g2' =
    put r1.lens g1 WrapClose,
    put r2.lens g2 WrapClose in
  let g = merge_epseq g1' g2' in
  let e = WrapSend (merge.obj_merge (send_obj e1) (send_obj e2)) in
  put r.lens g e

module MakeGlobal(X:LIN) = struct

  let put_ep r g ep =
    put r.lens g ep

  let make_send rB lab ch epA =
    let method_ v =
      Event.sync (Event.send ch v);
      X.mklin (Lazy.force epA)
    in
    (* <role_rB : < lab : v -> epA > > *)
    rB.label.make_obj (lab.make_obj method_)

  let make_recv rA lab ch epB =
    let wrapvar v epB =
      (* [`role_rA of [`lab of v * epB ] ] *)
      rA.label.make_var
        (lab.make_var (v, X.mklin epB))
    in
    Event.wrap
      (Event.receive ch)
      (fun v -> wrapvar v (Lazy.force epB))

  let ( --> ) rA rB label g0 =
    let ch = Event.new_channel ()
    in
    let epB = lazy (get_ep rB g0) in
    let ev  = make_recv rA label ch epB in
    let g1  = put_ep rB g0 (WrapRecv ev)
    in
    let epA = lazy (get_ep rA g1) in
    let obj = make_send rB label ch epA in
    let g2  = put_ep rA g1 (WrapSend obj)
    in g2
end

include MakeGlobal(struct type 'a lin = 'a let mklin x = x end)

module Lin : sig
  val ( --> ) :
    (_,  [>  ] as 'roleAvar, 'labelvar, 'epA, 'roleBobj,             'g1, 'g2) role ->
    (< .. > as 'roleBobj, _, 'labelobj, 'epB, 'roleAvar Event.event, 'g0, 'g1) role ->
    (< .. > as 'labelobj, [> ] as 'labelvar, 'v -> 'epA LinMonad.lin, 'v * 'epB LinMonad.lin) label ->
    'g0 lazy_t -> 'g2 lazy_t

  type 'g global

  val create_shared : (unit -> 'g epseq lazy_t) -> [>] list -> 'g global

  val connect :
    'g global ->
    (_, _, unit, 's, _, 'g epseq, _) role ->
    ('pre, 'pre, 's LinMonad.lin) LinMonad.monad

  open LinMonad

  val send :
    ((< .. > as 'obj) -> 'v data -> 's lin) ->
    'v ->
    ('obj lin, empty, 'pre, 'post) lens ->
    ('pre, 'post, 's lin) monad

  val deleg_send :
    ((< .. > as 'obj) -> 't lin -> 's lin) ->
    ('t lin, empty, 'pre, 'mid) lens ->
    ('obj lin, empty, 'mid, 'post) lens ->
    ('pre, 'post, 's lin) monad

  val receive :
    ('var Event.event lin, empty, 'pre, 'post) lens ->
    ('pre, 'post, 'var lin) monad

  val close :
    (close lin, empty, 'pre, 'post) lens ->
    ('pre, 'post, unit data) monad

end
  = struct
  module L = struct
    type 't lin = 't LinMonad.lin
    let mklin a = {LinMonad.__lindata=a}
  end

  module G = MakeGlobal(L)
  include G

  let stream_tee stream =
    failwith "TODO"

  type 'g global =
    {locals:(Obj.t * 'g epseq lazy_t Stream.t) list}

  let create_shared f rs =
    let st0 = Stream.from (fun _ -> Some (f ())) in
    match rs with
    | [] -> failwith "empty roles"
    | r::rs ->
       let st0, locals =
         List.fold_left
           (fun (st,xs) r ->
             let s1, s2 = stream_tee st in
             s2, (Obj.repr r, s1)::xs)
           (st0,[])
           rs
       in
       {locals=(Obj.repr r,st0)::locals}

  let connect {locals} r =
    {LinMonad.__run=
       fun pre->
       let st = List.assoc (Obj.repr (r.label.make_var ())) locals in
       Stream.next st |> (fun g ->
       (pre, {LinMonad.__lindata=unwrap @@ get r.lens g}))
    }

  let send sel v lens =
    let open LinMonad in
    {__run=
       fun pre ->
       let {__lindata=obj} = lens_get lens pre in
       let s = (sel obj {data=v}).__lindata in
       (lens_put lens pre Empty, {__lindata=s})
    }

  let deleg_send sel lens1 lens0 =
    let open LinMonad in
    {__run=
       fun pre ->
       let t = lens_get lens1 pre in
       let mid = lens_put lens1 pre Empty in
       let {__lindata=obj} = lens_get lens0 mid in
       let s = (sel obj t).__lindata in
       (lens_put lens0 mid Empty, {__lindata=s})
    }

  let receive lens =
    let open LinMonad in
    {__run=
       fun pre ->
       let {__lindata=s} = lens_get lens pre in
       let ls = Event.sync s in
       (lens_put lens pre Empty, {__lindata=ls})
    }

  let close lens =
    let open LinMonad in
    {__run=
       fun pre ->
       let {__lindata=s} = lens_get lens pre in
       let () = close s in
       (lens_put lens pre Empty, {data=()})
    }
end
