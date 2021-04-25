(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type refinement =
  | And of refinement * refinement
  | Or of refinement * refinement
  | Not of refinement
  | Truthy
  | Null
  | Undefined
  | Maybe
[@@deriving show { with_path = false }]

(* These functions are adapted from typing/refinement.ml. Eventually, this will be the only place
 * where refinement logic lives, so jmbrown is ok with this temporary duplication while he is
 * fleshing out the refinement features of EnvBuilder
 *
 * The purpose of these functions is to extract _what_ is being refined when we have something like
 * expr != null. What in expr does this refine? *)
let rec key =
  let open Flow_ast.Expression in
  function
  | (_, Identifier id) -> key_of_identifier id
  | _ ->
    (* other LHSes unsupported currently/here *)
    None

and key_of_identifier (_, { Flow_ast.Identifier.name; comments = _ }) =
  if name = "undefined" then
    None
  else
    Some name

module Make
    (L : Loc_sig.S)
    (Ssa_api : Ssa_api.S with module L = L)
    (Scope_builder : Scope_builder_sig.S with module L = L) =
struct
  module Ssa_builder = Ssa_builder.Make (L) (Ssa_api) (Scope_builder)

  let merge_and ref1 ref2 = And (ref1, ref2)

  let merge_or ref1 ref2 = Or (ref1, ref2)

  class env_builder =
    object (this)
      inherit Ssa_builder.ssa_builder as super

      val mutable expression_refinement_scopes = []

      val mutable refined_reads = L.LMap.empty

      method refined_reads : refinement L.LMap.t = refined_reads

      method private push_refinement_scope scope =
        expression_refinement_scopes <- scope :: expression_refinement_scopes

      method private pop_refinement_scope () =
        expression_refinement_scopes <- List.tl expression_refinement_scopes

      method private negate_new_refinements () =
        let head = List.hd expression_refinement_scopes in
        let head' = IMap.map (fun v -> Not v) head in
        expression_refinement_scopes <- head' :: List.tl expression_refinement_scopes

      method private peek_new_refinements () = List.hd expression_refinement_scopes

      method private merge_refinement_scopes ~merge scope1 scope2 =
        IMap.merge
          (fun _ ref1 ref2 ->
            match (ref1, ref2) with
            | (Some ref1, Some ref2) -> Some (merge ref1 ref2)
            | (Some ref, _) -> Some ref
            | (_, Some ref) -> Some ref
            | _ -> None)
          scope1
          scope2

      method private merge_self_refinement_scope scope1 =
        let scope2 = this#peek_new_refinements () in
        let scope = this#merge_refinement_scopes ~merge:merge_and scope1 scope2 in
        this#pop_refinement_scope ();
        this#push_refinement_scope scope

      method private find_refinement name =
        let writes = SMap.find_opt name this#ssa_env in
        match writes with
        | None -> None
        | Some writes ->
          let key = Ssa_builder.Val.id_of_val writes in
          List.fold_left
            (fun refinement refinement_scope ->
              match (IMap.find_opt key refinement_scope, refinement) with
              | (None, _) -> refinement
              | (Some refinement, None) -> Some refinement
              | (Some refinement, Some refinement') -> Some (And (refinement, refinement')))
            None
            expression_refinement_scopes

      method private add_refinement name refinement =
        let writes_to_loc = SMap.find name this#ssa_env in
        match expression_refinement_scopes with
        | scope :: scopes ->
          let scope' =
            IMap.update
              (Ssa_builder.Val.id_of_val writes_to_loc)
              (function
                | None -> Some refinement
                | Some r' -> Some (And (r', refinement)))
              scope
          in
          expression_refinement_scopes <- scope' :: scopes
        | _ -> failwith "Tried to add a refinement when no scope was on the stack"

      method identifier_refinement ((_loc, ident) as identifier) =
        ignore @@ this#identifier identifier;
        let { Flow_ast.Identifier.name; _ } = ident in
        this#add_refinement name Truthy

      method assignment_refinement loc assignment =
        ignore @@ this#assignment loc assignment;
        let open Flow_ast.Expression.Assignment in
        match assignment.left with
        | ( _,
            Flow_ast.Pattern.Identifier
              { Flow_ast.Pattern.Identifier.name = (_, { Flow_ast.Identifier.name; _ }); _ } ) ->
          this#add_refinement name Truthy
        | _ -> ()

      method logical_refinement expr =
        let { Flow_ast.Expression.Logical.operator; left; right; comments = _ } = expr in
        this#push_refinement_scope IMap.empty;
        ignore @@ this#expression_refinement left;
        let env1 = this#ssa_env in
        let refinement_scope1 = this#peek_new_refinements () in
        (match operator with
        | Flow_ast.Expression.Logical.Or -> this#negate_new_refinements ()
        | Flow_ast.Expression.Logical.And -> ()
        | Flow_ast.Expression.Logical.NullishCoalesce ->
          failwith "TODO logical_refinement nullish coalescing");
        this#push_refinement_scope IMap.empty;
        ignore @@ this#expression_refinement right;
        let refinement_scope2 = this#peek_new_refinements () in
        (* Pop RHS scope *)
        this#pop_refinement_scope ();
        (* Pop LHS scope *)
        this#pop_refinement_scope ();
        let merge =
          match operator with
          | Flow_ast.Expression.Logical.Or -> merge_or
          | _ -> merge_and
        in
        let refinement_scope =
          this#merge_refinement_scopes ~merge refinement_scope1 refinement_scope2
        in
        this#merge_self_refinement_scope refinement_scope;
        this#merge_self_ssa_env env1

      method null_test ~strict ~sense expr =
        ignore @@ this#expression expr;
        match key expr with
        | None -> ()
        | Some name ->
          let refinement =
            if strict then
              Null
            else
              Maybe
          in
          let refinement =
            if sense then
              refinement
            else
              Not refinement
          in
          this#add_refinement name refinement

      method undefined_test ~sense ~strict expr =
        ignore @@ this#expression expr;
        match key expr with
        | None -> ()
        | Some name ->
          (* Only add the refinement if undefined is not re-bound *)
          if SMap.find_opt "undefined" this#ssa_env = None then
            let refinement =
              if strict then
                Undefined
              else
                Maybe
            in
            let refinement =
              if sense then
                refinement
              else
                Not refinement
            in
            this#add_refinement name refinement

      method eq_test ~strict ~sense left right =
        let open Flow_ast in
        match (left, right) with
        (* expr op null *)
        | ((_, Expression.Literal { Literal.value = Literal.Null; _ }), expr)
        | (expr, (_, Expression.Literal { Literal.value = Literal.Null; _ })) ->
          this#null_test ~sense ~strict expr
        | ( (_, Expression.Identifier (_, { Flow_ast.Identifier.name = "undefined"; comments = _ })),
            expr )
        | ( expr,
            (_, Expression.Identifier (_, { Flow_ast.Identifier.name = "undefined"; comments = _ }))
          ) ->
          this#undefined_test ~sense ~strict expr
        | _ ->
          ignore @@ this#expression left;
          ignore @@ this#expression right

      method binary_refinement loc expr =
        let open Flow_ast.Expression.Binary in
        let { operator; left; right; comments = _ } = expr in
        match operator with
        (* == and != refine if lhs or rhs is an ident and other side is null *)
        | Equal -> this#eq_test ~strict:false ~sense:true left right
        | NotEqual -> this#eq_test ~strict:false ~sense:false left right
        | StrictEqual -> this#eq_test ~strict:true ~sense:true left right
        | StrictNotEqual -> this#eq_test ~strict:true ~sense:false left right
        | Instanceof ->
          (* TODO *)
          ignore @@ this#binary loc expr
        | LessThan
        | LessThanEqual
        | GreaterThan
        | GreaterThanEqual
        | In
        | LShift
        | RShift
        | RShift3
        | Plus
        | Minus
        | Mult
        | Exp
        | Div
        | Mod
        | BitOr
        | Xor
        | BitAnd ->
          ignore @@ this#binary loc expr

      method expression_refinement ((loc, expr) as expression) =
        let open Flow_ast.Expression in
        match expr with
        | Identifier ident ->
          this#identifier_refinement ident;
          expression
        | Logical logical ->
          this#logical_refinement logical;
          expression
        | Assignment assignment ->
          this#assignment_refinement loc assignment;
          expression
        | Binary binary ->
          this#binary_refinement loc binary;
          expression
        | Array _
        | ArrowFunction _
        | Call _
        | Class _
        | Comprehension _
        | Conditional _
        | Function _
        | Generator _
        | Import _
        | JSXElement _
        | JSXFragment _
        | Literal _
        | MetaProperty _
        | Member _
        | New _
        | Object _
        | OptionalCall _
        | OptionalMember _
        | Sequence _
        | Super _
        | TaggedTemplate _
        | TemplateLiteral _
        | TypeCast _
        | This _
        | Unary _
        | Update _
        | Yield _ ->
          this#expression expression

      method! logical _loc (expr : (L.t, L.t) Flow_ast.Expression.Logical.t) =
        let open Flow_ast.Expression.Logical in
        let { operator; left; right; comments = _ } = expr in
        this#push_refinement_scope IMap.empty;
        ignore @@ this#expression_refinement left;
        let env1 = this#ssa_env in
        (match operator with
        | Flow_ast.Expression.Logical.Or -> this#negate_new_refinements ()
        | Flow_ast.Expression.Logical.And -> ()
        | Flow_ast.Expression.Logical.NullishCoalesce ->
          failwith "nullish coalescing refinements are not yet implemented");
        ignore @@ this#expression right;
        this#pop_refinement_scope ();
        this#merge_self_ssa_env env1;
        expr

      (* This method is called during every read of an identifier. We need to ensure that
       * if the identifier is refined that we record the refiner as the write that reaches
       * this read *)
      method! any_identifier loc name =
        super#any_identifier loc name;
        match this#find_refinement name with
        | None -> ()
        | Some refinement -> refined_reads <- L.LMap.add loc refinement refined_reads
    end

  let program_with_scope ?(ignore_toplevel = false) program =
    let open Hoister in
    let (loc, _) = program in
    let ssa_walk = new env_builder in
    let bindings =
      if ignore_toplevel then
        Bindings.empty
      else
        let hoist = new hoister ~with_types:true in
        hoist#eval hoist#program program
    in
    ignore @@ ssa_walk#with_bindings loc bindings ssa_walk#program program;
    (ssa_walk#acc, ssa_walk#values, ssa_walk#refined_reads)

  let program program =
    let (_, _, refined_reads) = program_with_scope ~ignore_toplevel:false program in
    refined_reads
end

module With_Loc = Make (Loc_sig.LocS) (Ssa_api.With_Loc) (Scope_builder.With_Loc)
