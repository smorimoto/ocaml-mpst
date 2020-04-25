open Concur_shims

module type COMM = sig

  (** {2 Bare Channel Types} *)

  type ('v, 's) out
  (** Output of type 'v, then continue to session 's *)

  type 'var inp
  (** Input of type 'var *)

  type close
  (** Termination of a session *)

  type ('v, 's) scatter
  type 'var gather

  (** {2 Primitives} *)

  val send : ('v, 't) out -> 'v -> 't IO.io
  (** Output a value *)

  val receive : 'var inp -> 'var IO.io
  (** Input a value *)

  val close : close -> unit IO.io
  (** Close the channel *)

  val send_many : ('v, 't) scatter -> (int -> 'v) -> 't IO.io
  
  val receive_many : 'var gather -> 'var IO.io
end  

module type TYPES = sig
  (** First-class methods *)
  type ('obj,'mt) method_ = ('obj,'mt) Types.method_ =
    {make_obj: 'mt -> 'obj; call_obj: 'obj -> 'mt} (* constraint 'obj = < .. > *)

  (** Polymorphic lens; representing type-level indices *)
  type ('a,'b,'xs,'ys) idx = ('a,'b,'xs,'ys) Types.idx =
    Zero : ('a, 'b, [`cons of 'a * 'tl], [`cons of 'b * 'tl]) idx
  | Succ : ('a, 'b, 'aa, 'bb) idx -> ('a, 'b, [`cons of 'hd * 'aa], [`cons of 'hd * 'bb]) idx

  (** Message labels for global combinators. See examples. *)
  type ('obj,'ot,'var,'vt) label = ('obj,'ot,'var,'vt) Types.label =
    {obj: ('obj, 'ot) method_; var: 'vt -> 'var} (* constraint 'var = [>] *)

  (** Role types for global combinators. See examples *)
  type ('ts, 't, 'us, 'u, 'robj, 'mt) role = ('ts, 't, 'us, 'u, 'robj, 'mt) Types.role =
    {
      role_index: ('ts,'t,'us,'u) idx;
      (** The index of a role. Zero is "('x1*'y*'z, 'x1, 'x2*'y*'z, 'x2) idx" For three-role case. *)
      role_label:('robj,'mt) method_
      (** The label of a role. Normally it looks like (<role_A: 't>, 't) method_  *)
    }

  (** Disjoint concatenation/splitting of two objects  *)
  type ('lr, 'l, 'r) disj = ('lr, 'l, 'r) Types.disj =
    {disj_concat: 'l -> 'r -> 'lr;
    disj_splitL: 'lr -> 'l;
    disj_splitR: 'lr -> 'r;
    }
    (* constraint 'lr = < .. >
    * constraint 'l = < .. >
    * constraint 'r = < .. > *)

  type 'a one = 'a Types.one = One of 'a
end

module type GLOBAL_COMBINATORS = sig

  (** Common types *)
     
  type 't global
  (** Type of a global protocol specification, where 't is of form [`cons of 't1 * [`cons of 't2 * ...]] *)

  type 'a lin
  (** Linear type constructor, which is expanded to 'a when dynamic linearity checking  *)

  (** {2 Preamble} *)

  include TYPES

  (** {2 Erased Types (ignore this)} *)

  type ('v,'t) out
  type 'var inp
  type ('v,'t) scatter
  type 'var gather
  type close

  (** {2 Combinators} *)

  val ( --> ) :
    ('a one, 'b one, 'c, 'd, 'e, 'f inp) role ->
    ('g one, 'e one, 'h, 'c, 'b, 'i) role ->
    ('i, ('j, 'a) out, [>] as 'f, 'j * 'g lin) label -> 'h global -> 'd global
  (** Communication combinator. *)

  val gather :
    ('a list, 'b list, 'c, 'd, 'e, 'f gather) role ->
    ('g one, 'e one, 'h, 'c, 'b, 'i) role ->
    ('i, ('j, 'a) out, [>] as 'f, 'j list * 'g lin) label ->
    'h global -> 'd global

  val scatter :
    ('a one, 'b one, 'c, 'd, 'e, 'f inp) role ->
    ('g list, 'e list, 'h, 'c, 'b, 'i) role ->
    ('i, ('j, 'a) scatter, [>] as 'f, 'j * 'g lin) label ->
    'h global -> 'd global

  val choice_at :
    ('a one, 'b one, 'c, 'd, 'e, 'f) role ->
    ('b, 'g, 'h) disj ->
    ('g one, unit one, 'i, 'c, 'j, 'k) role * 'i global ->
    ('h one, unit one, 'm, 'c, 'n, 'o) role * 'm global ->
    'd global

  val fix : ('g global -> 'g global) -> 'g global

  val finish : ([ `cons of close one * 'a ] as 'a) global

  val finish_with_multirole :
    at:(close one, close list, [ `cons of close one * 'a ] as 'a, 'g, _, _) role ->
    'g global

  val with_multirole :
    at:(close one, close list, 'g0, 'g1, 'a, 'b) role ->
    'g0 global -> 'g1 global

  val closed_at :
    (close one, close one, 'g, 'g, 'a, 'b) role ->
    'g global -> 'g global

  val closed_list_at :
    (close list, close list, 'g, 'g, 'a, 'b) role ->
    'g global -> 'g global

  (** {2 Getting Types} *)
  
  type 'a ty

  val get_ty : ('a one, 'b, 'c, 'd, 'e, 'f) role -> 'c global -> 'a lin ty

  val get_ty_list : ('a list, 'b, 'c, 'd, 'e, 'f) role -> 'c global -> 'a lin ty

  val (>:) :
    ('obj,('v, 'epA) out, 'var, 'v * 'epB) label ->
    'v ty ->
    ('obj,('v, 'epA) out, 'var, 'v * 'epB) label

  val (>>:) :
    ('obj,('v, 'epA) scatter, 'var, 'v * 'epB) label ->
    'v ty ->
    ('obj,('v, 'epA) scatter, 'var, 'v * 'epB) label
end

module type GEN = sig
  

end  

module type GLOBAL_COMBINATORS_DYN = sig

  (** {1 Communication Primitives} *)
  include COMM

  (** {1 Global Combinators} *)
  include GLOBAL_COMBINATORS
    with type ('v,'t) out := ('v,'t) out
    and type 'var inp := 'var inp
    and type ('v,'t) scatter := ('v,'t) scatter
    and type 'var gather := 'var gather
    and type close := close

  (** {1 Extracting Channel Vectors From Global Combinators} *)

  type 't tup
  (** Sequence of channels, where 't is of form [`cons of 't1 * [`cons of 't2 ...]]  *)

  val gen_with_env : Env.t -> 'a global -> 'a tup

  val gen : 'a global -> 'a tup

  val gen_mult : int list -> 'a global -> 'a tup

  val gen_with_kinds: [< `IPCProcess | `Local | `Untyped ] list -> 'a global -> 'a tup

  val gen_with_kinds_mult: ([< `IPCProcess | `Local | `Untyped ] * int) list -> 'a global -> 'a tup

  val get_ch : ('a one, 'b, 'c, 'd, 'e, 'f) role -> 'c tup -> 'a

  val get_ch_list : ('a list, 'b, 'c, 'd, 'e, 'f) role -> 'c tup -> 'a list

  val get_ch_ : ('a one, close one, 'c, 'd, 'e, 'f) role -> 'c tup -> 'a * 'd tup

  val get_ch_list_ : ('a list, close one, 'c, 'd, 'e, 'f) role -> 'c tup -> 'a list * 'd tup

  val get_ty_ : ('a one, 'b, 'c, 'd, 'e, 'f) role -> 'c tup -> 'a lin ty

  val get_ty_list_ : ('a list, 'b, 'c, 'd, 'e, 'f) role -> 'c tup -> 'a lin ty

  val effective_length : 't tup -> int

  val env : 't tup -> Env.t
end                                   

module type SHARED =   sig
  
  include GLOBAL_COMBINATORS_DYN

  (** {1 Shared Channels} *)

  type kind = [ `IPCProcess | `Local | `Untyped ]

  type 't shared

  val create_shared :
    ?kinds:(kind * int) list ->
    [ `cons of 'a * 'b ] global ->
    [ `cons of 'a * 'b ] shared

  val accept_ :
    [ `cons of 'a * 'b ] shared ->
    ('c one, 'd, [ `cons of 'a * 'b ], 'e, 'f, 'g) role ->
    'c IO.io

  val connect_ :
    [ `cons of 'a * 'b ] shared ->
    ('c one, 'd, [ `cons of 'a * 'b ], 'e, 'f, 'g) role ->
    'c IO.io

  val accept :
    [ `cons of 'a * 'b ] shared ->
    ('c one, 'd, [ `cons of 'a * 'b ], 'e, 'f, 'g) role ->
    'c IO.io

  val connect :
    [ `cons of 'a * 'b ] shared ->
    ('c one, 'd, [ `cons of 'a * 'b ], 'e, 'f, 'g) role ->
    'c IO.io
end