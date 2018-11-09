(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast_utils = Flow_ast_utils

let spf = Printf.sprintf

module Sort = Signature_builder_kind.Sort

module Make (L: Loc_sig.S) : Signature_builder_deps_sig.S with module L = L = struct
  module L = L
  module Error = struct
    type t =
      | ExpectedSort of Sort.t * string * L.t
      | ExpectedAnnotation of L.t
      | InvalidTypeParamUse of L.t
      | UnexpectedObjectKey of L.t * L.t
      | UnexpectedObjectSpread of L.t * L.t
      | UnexpectedArraySpread of L.t * L.t
      | UnexpectedArrayHole of L.t
      | EmptyArray of L.t
      | EmptyObject of L.t
      | UnexpectedExpression of L.t * Ast_utils.ExpressionSort.t
      | SketchyToplevelDef of L.t
      | TODO of string * L.t

    let compare = Pervasives.compare

    let debug_to_string = function
      | ExpectedSort (sort, x, loc) ->
        spf "%s @ %s is not a %s"
          x (L.debug_to_string loc) (Sort.to_string sort)
      | ExpectedAnnotation loc -> spf "Expected annotation @ %s" (L.debug_to_string loc)
      | InvalidTypeParamUse loc -> spf "Invalid use of type parameter @ %s" (L.debug_to_string loc)
      | UnexpectedObjectKey (_loc, key_loc) ->
        spf "Expected simple object key @ %s" (L.debug_to_string key_loc)
      | UnexpectedObjectSpread (_loc, spread_loc) ->
        spf "Unexpected object spread @ %s" (L.debug_to_string spread_loc)
      | UnexpectedArraySpread (_loc, spread_loc) ->
        spf "Unexpected array spread @ %s" (L.debug_to_string spread_loc)
      | UnexpectedArrayHole loc -> spf "Unexpected array hole @ %s" (L.debug_to_string loc)
      | EmptyArray loc ->
        spf "Cannot determine element type of empty array @ %s" (L.debug_to_string loc)
      | EmptyObject loc ->
        spf "Cannot determine types of initialized properties of empty object @ %s"
          (L.debug_to_string loc)
      | UnexpectedExpression (loc, esort) ->
        spf "Expected literal expression instead of %s @ %s"
          (Ast_utils.ExpressionSort.to_string esort) (L.debug_to_string loc)
      | SketchyToplevelDef loc ->
        spf "Unexpected toplevel definition that needs hoisting @ %s" (L.debug_to_string loc)
      | TODO (msg, loc) -> spf "TODO: %s @ %s" msg (L.debug_to_string loc)

  end
  module ErrorSet = Set.Make (Error)

  module Dep = struct
    type t =
      | Local of local
      | Dynamic of dynamic
      | Remote of remote

    and local = Sort.t * string

    and dynamic =
      | Class of L.t * string
      | DynamicImport of L.t
      | DynamicRequire of L.t

    and remote =
      | ImportNamed of {
          sort: Sort.t;
          source: L.t Ast_utils.source;
          name: L.t Ast_utils.ident;
        }
      | ImportStar of {
          sort: Sort.t;
          source: L.t Ast_utils.source;
        }
      | Require of {
          source: L.t Ast_utils.source;
          name: L.t Ast_utils.ident option;
        }
      | Global of local

    let compare = Pervasives.compare

    let expectation sort x loc = Error.ExpectedSort (sort, x, loc)

    let remote = function
      | Remote _ -> true
      | Local _ | Dynamic _ -> false

    let local_uses dep acc = match dep with
      | Local (_, n) -> SSet.add n acc
      | Remote _ | Dynamic _ -> acc

    let to_string =
      let string_of_import_sort = function
        | Sort.Value -> "import"
        | Sort.Type -> "import type" in
      let string_of_local (sort, x) =
        spf "%s: %s" (Sort.to_string sort) x in
      let string_of_dynamic = function
        | Class (loc, x) -> spf "class %s @ %s" x (L.debug_to_string loc)
        | DynamicImport loc -> spf "import @ %s" (L.debug_to_string loc)
        | DynamicRequire loc -> spf "require @ %s" (L.debug_to_string loc) in
      let string_of_remote = function
        | ImportNamed { sort; name = (_, n); source = (_, m) } ->
          spf "%s { %s } from '%s'" (string_of_import_sort sort) n m
        | ImportStar { sort; source = (_, m) } ->
          spf "%s * from '%s'" (string_of_import_sort sort) m
        | Require { source = (_, m); name } ->
          begin match name with
            | None -> spf "require('%s')" m
            | Some (_, n) -> spf "require('%s').%s" m n
          end
        | Global local -> spf "global %s" (string_of_local local)
      in function
        | Local local -> string_of_local local
        | Dynamic dynamic -> string_of_dynamic dynamic
        | Remote remote -> string_of_remote remote
  end

  module DepSet = Set.Make (Dep)

  type t = DepSet.t * ErrorSet.t

  let join ((deps1, msgs1), (deps2, msgs2)) =
    DepSet.union deps1 deps2, ErrorSet.union msgs1 msgs2

  let bot = DepSet.empty, ErrorSet.empty
  let top msg = DepSet.empty, ErrorSet.singleton msg

  let unreachable = bot
  let todo loc msg = top (Error.TODO (msg, loc))

  let unit dep = DepSet.singleton dep, ErrorSet.empty

  let type_ atom = unit Dep.(Local (Sort.Type, atom))
  let value atom = unit Dep.(Local (Sort.Value, atom))

  let dynamic_import loc = unit Dep.(Dynamic (DynamicImport loc))
  let dynamic_require loc = unit Dep.(Dynamic (DynamicRequire loc))

  let import_named sort source name = unit Dep.(Remote (ImportNamed { sort; source; name }))
  let import_star sort source = unit Dep.(Remote (ImportStar { sort; source }))
  let require ?name source = unit Dep.(Remote (Require { source; name }))
  let global local = unit Dep.(Remote (Global local))

  let reduce_join f deps x =
    join (deps, f x)

  let recurse f (deps, msgs) =
    DepSet.fold (fun dep msgs -> ErrorSet.union (f dep) msgs) deps msgs

  let replace_local_with_dynamic_class (loc, x) (deps, msgs) =
    let acc = DepSet.fold (fun dep acc -> match dep with
      | Dep.Local (_, y) when x = y -> acc
      | _ -> join (acc, unit dep)
    ) deps (DepSet.empty, msgs) in
    join (acc, unit (Dep.Dynamic (Dep.Class (loc, x))))
end

module With_Loc = Make (Loc_sig.LocS)
module With_ALoc = Make (Loc_sig.ALocS)

include With_Loc

let abstractify_error =
  let module WL = With_Loc.Error in
  let module WA = With_ALoc.Error in
  function
  | WL.ExpectedSort (sort, str, loc) -> WA.ExpectedSort (sort, str, ALoc.of_loc loc)
  | WL.ExpectedAnnotation loc -> WA.ExpectedAnnotation (ALoc.of_loc loc)
  | WL.InvalidTypeParamUse loc -> WA.InvalidTypeParamUse (ALoc.of_loc loc)
  | WL.UnexpectedObjectKey (loc, key_loc) ->
    WA.UnexpectedObjectKey (ALoc.of_loc loc, ALoc.of_loc key_loc)
  | WL.UnexpectedObjectSpread (loc, spread_loc) ->
    WA.UnexpectedObjectSpread (ALoc.of_loc loc, ALoc.of_loc spread_loc)
  | WL.UnexpectedArraySpread (loc, spread_loc) ->
    WA.UnexpectedArraySpread (ALoc.of_loc loc, ALoc.of_loc spread_loc)
  | WL.UnexpectedArrayHole loc -> WA.UnexpectedArrayHole (ALoc.of_loc loc)
  | WL.EmptyArray loc -> WA.EmptyArray (ALoc.of_loc loc)
  | WL.EmptyObject loc -> WA.EmptyObject (ALoc.of_loc loc)
  | WL.UnexpectedExpression (loc, sort) -> WA.UnexpectedExpression (ALoc.of_loc loc, sort)
  | WL.SketchyToplevelDef loc -> WA.SketchyToplevelDef (ALoc.of_loc loc)
  | WL.TODO (str, loc) -> WA.TODO (str, ALoc.of_loc loc)
