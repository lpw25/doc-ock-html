(*
 * Copyright (c) 2016 Thomas Refis <trefis@janestreet.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)
open StdLabels

open DocOck
open Paths

open Tyxml.Html

type ('inner, 'outer) text =
  [> `PCDATA | `Span | `A of ([> `PCDATA ] as 'inner) ] as 'outer

let a_href = Html_tree.Relative_link.to_sub_element

let rec list_concat_map ?sep ~f = function
  | [] -> []
  | [x] -> f x
  | x :: xs ->
    let hd = f x in
    let tl = list_concat_map ?sep ~f xs in
    match sep with
    | None -> hd @ tl
    | Some sep -> hd @ sep :: tl

let functor_arg_pos { Types.FunctorArgument.id ; _ } =
  match id with
  | Identifier.Argument (_, nb, _) -> nb
  | _ ->
    let id = string_of_sexp @@ Identifier.sexp_of_t (fun _ -> Atom "") id in
    invalid_arg (Printf.sprintf "functor_arg_pos: %s" id)

let rec unit ~get_package (t : _ Types.Unit.t) : Html_tree.t =
  let package =
    match t.id with
    | Paths.Identifier.Root (a, _) -> get_package a
    | _ -> assert false
  in
  Html_tree.enter package;
  Html_tree.enter (Identifier.name t.id);
  let header_doc = Documentation.to_html ~get_package t.doc in
  let html, subtree =
    match t.content with
    | Module sign -> signature ~get_package sign
    | Pack packed -> pack ~get_package packed, []
  in
  Html_tree.make (header_doc @ html, subtree)

and pack
   : get_package:('a -> string) -> 'a Types.Unit.Packed.t
  -> Html_types.div_content_fun elt list
= fun ~get_package t ->
  let open Types in
  List.map t ~f:(fun x ->
    let modname = Identifier.name x.Unit.Packed.id in
    let md_def =
      Markup.keyword "module " ::
      pcdata modname ::
      pcdata " = " ::
      Html_tree.Relative_link.of_path ~stop_before:false ~get_package x.path
    in
    Markup.make_def ~get_package ~id:x.Unit.Packed.id ~code:md_def ~doc:[]
  )

and signature
   : get_package:('a -> string) -> 'a Types.Signature.t
  -> Html_types.div_content_fun elt list * Html_tree.t list
= fun ~get_package t ->
  let html_and_subtrees =
    let recording_doc = ref true in
    List.map t ~f:(fun item ->
      if not !recording_doc then (
        begin match item with
        | Types.Signature.Comment Stop -> recording_doc := not !recording_doc
        | _ -> ()
        end;
        [], []
      ) else (
        match item with
        | Types.Signature.Module md -> module_ ~get_package md
        | ModuleType mty -> module_type ~get_package mty
        | Type td -> [ type_decl ~get_package td ], []
        | TypExt te -> [ extension ~get_package te ], []
        | Exception e -> [ exn ~get_package e ], []
        | Value v -> [ value ~get_package v ], []
        | External e -> [ external_ ~get_package e ], []
        | Class c -> class_ ~get_package c
        | ClassType cty -> class_type ~get_package cty
        | Include incl -> include_ ~get_package incl
        | Comment (Documentation doc) ->
          Documentation.to_html ~get_package doc, []
        | Comment Stop ->
          recording_doc := not !recording_doc;
          [], []
      )
    )
  in
  let html, subtrees = List.split html_and_subtrees in
  List.concat html, List.concat subtrees

and functor_argument
   : 'row. get_package:('a -> string) -> 'a Types.FunctorArgument.t
  -> ([> Html_types.div ] as 'row) elt * Html_tree.t list
= fun ~get_package arg ->
  let open Types.FunctorArgument in
  let name = Identifier.name arg.id in
  let nb = functor_arg_pos arg in
  let link_name = Printf.sprintf "%d-%s" nb name in
  let def_div, subtree =
    match arg.expansion with
    | None ->
      (
        pcdata (Identifier.name arg.id) ::
        pcdata " : " ::
        mty ~get_package (Identifier.signature_of_module arg.id) arg.expr
      ), []
    | Some expansion ->
      let expansion =
        match expansion with
        | AlreadyASig ->
          begin match arg.expr with
          | Signature sg -> Types.Module.Signature sg
          | _ -> assert false
          end
        | e -> e
      in
      Html_tree.enter ~kind:(`Arg) link_name;
      let node = module_expansion ~get_package expansion in
      let subtree = Html_tree.make node in
      Html_tree.leave ();
      (
        a ~a:[ a_href ~kind:`Arg link_name ] [pcdata name] ::
        pcdata " : " ::
        mty ~get_package (Identifier.signature_of_module arg.id) arg.expr
      ), [subtree]
  in
  let region =
    Markup.make_def ~get_package ~id:arg.id ~code:def_div ~doc:[]
  in
  region, subtree

and module_expansion
   : get_package:('a -> string) -> 'a Types.Module.expansion
  -> Html_types.div_content_fun elt list * Html_tree.t list
= fun ~get_package t ->
  match t with
  | AlreadyASig -> assert false
  | Signature sg -> signature ~get_package sg
  | Functor (args, sg) ->
    let sig_html, subpages = signature ~get_package sg in
    let params, params_subpages =
      List.fold_left args ~init:([], []) ~f:(fun (args, subpages as acc) arg ->
        match arg with
        | None -> acc
        | Some arg ->
          let arg, arg_subpages = functor_argument ~get_package arg in
          (arg :: args, arg_subpages @ subpages)
      )
    in
    let html =
      h3 ~a:[ a_class ["heading"] ] [ pcdata "Parameters" ] ::
      div params ::
      h3 ~a:[ a_class ["heading"] ] [ pcdata "Signature" ] ::
      sig_html
    in
    html, params_subpages @ subpages

and module_
   : 'row. get_package:('a -> string) -> 'a Types.Module.t
  -> ([> Html_types.div ] as 'row) elt list * Html_tree.t list
= fun ~get_package t ->
  let modname = Identifier.name t.id in
  let md =
    module_decl ~get_package (Identifier.signature_of_module t.id)
      (match t.display_type with
       | None -> t.type_
       | Some t -> t)
  in
  let modname, subtree =
    match t.expansion with
    | None -> pcdata modname, []
    | Some expansion ->
      let expansion =
        match expansion with
        | AlreadyASig ->
          begin match t.type_ with
          | ModuleType (Types.ModuleType.Signature sg) ->
            Types.Module.Signature sg
          | _ -> assert false
          end
        | e -> e
      in
      Html_tree.enter ~kind:(`Mod) modname;
      let doc = Documentation.to_html ~get_package t.doc in
      let expansion, subpages = module_expansion ~get_package expansion in
      let expansion =
        match doc with
        | [] -> expansion
        | _ -> div ~a:[ a_class ["doc"] ] doc :: expansion
      in
      let subtree = Html_tree.make (expansion, subpages) in
      Html_tree.leave ();
      a ~a:[ a_href ~kind:`Mod modname ] [pcdata modname], [subtree]
  in
  let md_def_content = Markup.keyword "module " :: modname :: md in
  let region =
    Markup.make_def ~get_package ~id:t.id ~code:md_def_content
      ~doc:(Documentation.first_to_html ~get_package t.doc)
  in
  [ region ], subtree

and module_decl ~get_package (base : _ Identifier.signature) md =
  begin match md with
  | Alias _ -> pcdata " = "
  | ModuleType _ -> pcdata " : "
  end ::
  module_decl' ~get_package base md

and extract_path_from_mt ~(default: 'a Identifier.signature) =
  let open Types.ModuleType in
  function
  | Path (Path.Resolved r) ->
    Identifier.signature_of_module_type (Path.Resolved.identifier r)
  | With (mt, _) -> extract_path_from_mt ~default mt
  | TypeOf (Types.Module.Alias (Path.Resolved r)) ->
    Identifier.signature_of_module (Path.Resolved.identifier r)
  | TypeOf (Types.Module.ModuleType mt) -> extract_path_from_mt ~default mt
  | _ -> default

and module_decl'
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Identifier.signature -> 'a Types.Module.decl
  -> ('inner_row, 'outer_row) text elt list
= fun ~get_package base -> function
  | Alias mod_path -> Html_tree.Relative_link.of_path ~stop_before:true ~get_package mod_path
  | ModuleType mt -> mty ~get_package (extract_path_from_mt ~default:base mt) mt

and module_type ~get_package (t : _ Types.ModuleType.t) =
  let modname = Identifier.name t.id in
  let mty =
    match t.expr with
    | None -> []
    | Some expr ->
      begin match expr with
      | Path _ -> pcdata " = "
      | _ -> pcdata " : "
      end ::
      mty ~get_package (Identifier.signature_of_module_type t.id) expr
  in
  let modname, subtree =
    match t.expansion with
    | None -> pcdata modname, []
    | Some expansion ->
      let expansion =
        match expansion with
        | AlreadyASig ->
          begin match t.expr with
          | Some (Signature sg) -> Types.Module.Signature sg
          | _ -> assert false
          end
        | e -> e
      in
      Html_tree.enter ~kind:(`Mty) modname;
      let doc = Documentation.to_html ~get_package t.doc in
      let expansion, subpages = module_expansion ~get_package expansion in
      let expansion =
        match doc with
        | [] -> expansion
        | _ -> div ~a:[ a_class ["doc"] ] doc :: expansion
      in
      let subtree = Html_tree.make (expansion, subpages) in
      Html_tree.leave ();
      a ~a:[ a_href ~kind:`Mty modname ] [pcdata modname], [subtree]
  in
  let mty_def =
    (
      Markup.keyword "module type " ::
      modname ::
      mty
    )
  in
  let region =
    Markup.make_def ~get_package ~id:t.id ~code:mty_def
      ~doc:(Documentation.first_to_html ~get_package t.doc)
  in
  [ region ], subtree

and mty
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Identifier.signature -> 'a Types.ModuleType.expr
  -> ('inner_row, 'outer_row) text elt list
= fun ~get_package (base : _ Identifier.signature) -> function
  | Path mty_path -> Html_tree.Relative_link.of_path ~stop_before:true ~get_package mty_path
  | Signature _ ->
    [ Markup.keyword "sig" ; pcdata " ... " ; Markup.keyword "end" ]
  | Functor (None, expr) ->
    Markup.keyword "functor" :: pcdata " () " ::
    mty ~get_package base expr
  | Functor (Some arg, expr) ->
    let name =
      let open Types.FunctorArgument in
      let to_print = pcdata @@ Identifier.name arg.id in
      match
        Html_tree.Relative_link.Id.href ~get_package
          ~stop_before:(arg.expansion = None) arg.id
      with
      | exception _ -> to_print
      | href -> a ~a:[ Tyxml.Html.a_href href ] [ to_print ]
    in
    Markup.keyword "functor" ::
    pcdata " (" :: name :: pcdata " : " ::
    mty ~get_package base arg.expr @
    pcdata ") -> " ::
    mty ~get_package base expr
  | With (expr, substitutions) ->
    mty ~get_package base expr @
    Markup.keyword " with " ::
    list_concat_map ~sep:(Markup.keyword " and ") substitutions
      ~f:(substitution ~get_package base)
  | TypeOf md ->
    Markup.keyword "module type of " :: module_decl' ~get_package base md

and substitution
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Identifier.signature -> 'a Types.ModuleType.substitution
  -> ('inner_row, 'outer_row) text elt list
= fun ~get_package base -> function
  | ModuleEq (frag_mod, md) ->
    Markup.keyword "module " ::
    Html_tree.Relative_link.of_fragment ~get_package ~base
      (Fragment.signature_of_module frag_mod)
    @ pcdata " = " ::
    module_decl' ~get_package base md
  | TypeEq (frag_typ, td) ->
    Markup.keyword "type " ::
    format_params td.Types.TypeDecl.Equation.params ::
    Html_tree.Relative_link.of_fragment ~get_package ~base (Fragment.any_sort frag_typ) @
    fst (format_manifest ~get_package td) @
    format_constraints ~get_package td.Types.TypeDecl.Equation.constraints
  | ModuleSubst (frag_mod, mod_path) ->
    Markup.keyword "module " ::
    Html_tree.Relative_link.of_fragment ~get_package ~base (Fragment.signature_of_module frag_mod) @
    pcdata " := " ::
    Html_tree.Relative_link.of_path ~stop_before:true ~get_package mod_path
  | TypeSubst (frag_typ, vars, typ_path) ->
    let params =
      pcdata begin match vars with
        | [] -> ""
        | [v] -> v ^ "\194\160"
        | _ -> "(" ^ String.concat ~sep:",\194\160" vars ^ ")\194\160"
      end
    in
    Markup.keyword "type " ::
    params ::
    Html_tree.Relative_link.of_fragment ~get_package ~base (Fragment.any_sort frag_typ) @
    pcdata " := " ::
    params ::
    Html_tree.Relative_link.of_path ~stop_before:false ~get_package typ_path

and constructor
   : 'b. get_package:('a -> string)
  -> ('a, 'b) Identifier.t -> 'a Types.TypeDecl.Constructor.argument
  -> 'a Types.TypeExpr.t option
  -> [> `Code | `PCDATA | `Table ] elt list
= fun ~get_package id args ret_type ->
    let name = Identifier.name id in
    let cstr = span ~a:[ a_class [ Url.kind_of_id_exn ~get_package id ] ] [ pcdata name ] in
    let is_gadt, ret_type =
      match ret_type with
      | None -> false, []
      | Some te ->
        let constant =
          match args with
          | Tuple [] -> true
          | _ -> false
        in
        let ret_type =
          pcdata " " ::
          (if constant then Markup.keyword ":" else Markup.arrow) ::
          pcdata " " ::
          type_expr ~get_package te
        in
        true, ret_type
    in
    match args with
    | Tuple [] -> [ code (cstr :: ret_type) ]
    | Tuple lst ->
      [ code (
          cstr ::
          Markup.keyword (if is_gadt then " : " else " of ") ::
          list_concat_map lst ~sep:(Markup.keyword " * ")
            ~f:(type_expr ~needs_parentheses:is_gadt ~get_package)
          @ ret_type
        )
      ]
    | Record fields ->
      code [ cstr; Markup.keyword (if is_gadt then " : " else " of ") ]
      :: record ~get_package fields
      @ [ code ret_type ]

and format_params
   : 'row. ?delim:[`parens | `brackets] -> Types.TypeDecl.param list
  -> ([> `PCDATA ] as 'row) elt
= fun ?(delim=`parens) params ->
  let format_param (desc, variance_opt) =
    let param_desc = match desc with | Types.TypeDecl.Any -> "_" | Var s -> "'" ^ s in
    match variance_opt with
    | None -> param_desc
    | Some Types.TypeDecl.Pos -> "+" ^ param_desc
    | Some Types.TypeDecl.Neg -> "-" ^ param_desc
  in
  pcdata (
    match params with
    | [] -> ""
    | [x] -> format_param x ^ " "
    | lst ->
      let params = String.concat ~sep:", " (List.map lst ~f:format_param) in
      (match delim with `parens -> "(" | `brackets -> "[")
      ^ params ^
      (match delim with `parens -> ") " | `brackets -> "] ")
  )

and format_constraints
  : 'inner_row 'outer_row. get_package:_ -> (_ * _) list ->
  ([> `PCDATA | `Span
   | `A of ([> `PCDATA ] as 'inner_row) ] as 'outer_row) elt list
  = fun ~get_package -> function
  | [] -> []
  | lst ->
    Markup.keyword " constraint " ::
    list_concat_map lst ~sep:(Markup.keyword " and ") ~f:(fun (t1, t2) ->
      type_expr ~get_package t1 @ pcdata " = " :: type_expr ~get_package t2
    )

and format_manifest
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> ?compact_variants:bool
  -> 'a Types.TypeDecl.Equation.t
  -> ('inner_row, 'outer_row) text elt list * bool
= fun ~get_package ?(compact_variants=true) equation ->
  let _ = compact_variants in (* TODO *)
  let private_ = equation.private_ in
  match equation.manifest with
  | None -> [], private_
  | Some t ->
    let manifest =
      Markup.keyword " = " ::
      (if private_ then Markup.keyword "private " else pcdata "") ::
      type_expr ~get_package t
    in
    manifest, false

and polymorphic_variant ~get_package ~type_ident (t : _ Types.TypeExpr.Variant.t) =
  let row item =
    let kind_approx, cstr =
      match item with
      | Types.TypeExpr.Variant.Type te ->
        "unknown", [code (type_expr ~get_package te)]
      | Constructor (name, _bool, args) ->
        let cstr = "`" ^ name in
        "constructor",
        match args with
        | [] -> [code [ pcdata cstr ]]
        | _ ->
          [ code (
              pcdata cstr ::
              Markup.keyword " of " ::
              list_concat_map args ~sep:(Markup.keyword " * ")
                ~f:(type_expr ~get_package)
            )
          ]
    in
    try
      let { Url.Anchor. name = anchor; kind } =
        Url.Anchor.Polymorphic_variant_decl.from_element
          ~get_package ~type_ident item
      in
      tr ~a:[ a_id anchor; a_class ["anchored"] ] [
        td ~a:[ a_class ["def"; kind] ] (
          a ~a:[ Tyxml.Html.a_href ("#" ^ anchor); a_class ["anchor"] ] [] ::
          code [Markup.keyword "| " ] ::
          cstr
        );
        (* TODO: retrieve doc comments. *)
      ]
    with Failure s ->
      Printf.eprintf "ERROR: %s\n%!" s;
      tr [
        td ~a:[ a_class ["def"; kind_approx] ] (
          code [Markup.keyword "| " ] ::
          cstr
        );
        (* TODO: retrieve doc comments. *)
      ]
  in
  let table = table ~a:[a_class ["variant"]] (List.map t.elements ~f:row) in
  match t.kind with
  | Fixed -> code [pcdata "[ "] :: table :: [code [pcdata " ]"]]
  | Open -> code [pcdata "[> "] :: table :: [code [pcdata " ]"]]
  | Closed [] -> code [pcdata "[< "] :: table :: [code [pcdata " ]"]]
  | Closed lst ->
    let constrs = String.concat ~sep:" " lst in
    code [pcdata "[< "] :: table :: [code [pcdata (" " ^ constrs ^ " ]")]]


and variant ~get_package cstrs : [> Html_types.table ] elt =
  let constructor id args res =
    match Url.from_identifier ~get_package ~stop_before:true id with
    | Error e -> failwith (Url.Error.to_string e)
    | Ok { anchor; kind; _ } ->
      let cell =
        td ~a:[ a_class ["def"; kind ] ] (
          a ~a:[ Tyxml.Html.a_href ("#" ^ anchor); a_class ["anchor"] ] [] ::
          code [Markup.keyword "| " ] ::
          constructor ~get_package id args res
        )
      in
      anchor, cell
  in
  let rows =
    List.map cstrs ~f:(fun cstr ->
      let open Types.TypeDecl.Constructor in
      let anchor, lhs = constructor cstr.id cstr.args cstr.res in
      let rhs = Documentation.to_html ~wrap:() ~get_package cstr.doc in
      tr ~a:[ a_id anchor; a_class ["anchored"] ] (
        lhs ::
        if not (Documentation.has_doc cstr.doc) then [] else [
          td ~a:[ a_class ["doc"] ] rhs
        ]
      )
    )
  in
  table ~a:[ a_class ["variant"] ] rows

and record ~get_package fields =
  let field mutable_ id typ =
    match Url.from_identifier ~get_package ~stop_before:true id with
    | Error e -> failwith (Url.Error.to_string e)
    | Ok { anchor; kind; _ } ->
      let name = Identifier.name id in
      let cell =
        td ~a:[ a_class ["def"; kind ] ]
          [ a ~a:[ Tyxml.Html.a_href ("#" ^ anchor); a_class ["anchor"] ] []
          ; code (
              (if mutable_ then Markup.keyword "mutable " else pcdata "")
              :: (pcdata name)
              :: (pcdata " : ")
              :: (type_expr ~get_package typ)
              @  [pcdata ";"]
            )
          ]
      in
      anchor, cell
  in
  let rows =
    List.map fields ~f:(fun fld ->
      let open Types.TypeDecl.Field in
      let anchor, lhs = field fld.mutable_ fld.id fld.type_ in
      let rhs = Documentation.to_html ~wrap:() ~get_package fld.doc in
      tr ~a:[ a_id anchor; a_class ["anchored"] ] (
        lhs ::
        if not (Documentation.has_doc fld.doc) then [] else [
          td ~a:[ a_class ["doc"] ] rhs
        ]
      )
    )
  in
  [ code [pcdata "{"]
  ; table ~a:[ a_class ["record"] ] rows
  ; code [pcdata "}"]]

and type_decl ~get_package (t : _ Types.TypeDecl.t) =
  let tyname = Identifier.name t.id in
  let params = format_params t.equation.params in
  let constraints = format_constraints ~get_package t.equation.constraints in
  let manifest, need_private =
    match t.equation.manifest with
    | Some (Types.TypeExpr.Variant variant) ->
      let manifest =
        Markup.keyword " = " ::
        (if t.equation.private_ then Markup.keyword "private " else pcdata "") ::
        polymorphic_variant ~get_package ~type_ident:t.id variant
      in
      manifest, false
    | _ ->
      let manifest, need_private = format_manifest ~get_package t.equation in
      [code manifest], need_private
  in
  let representation =
    match t.representation with
    | None -> []
    | Some repr ->
      code [
        Markup.keyword " = ";
        if need_private then Markup.keyword "private " else pcdata ""
      ] ::
      match repr with
      | Extensible -> [code [Markup.keyword  ".."]]
      | Variant cstrs -> [variant ~get_package cstrs]
      | Record fields -> record ~get_package fields
  in
  let doc = Documentation.to_html ~get_package t.doc in
  let tdecl_def =
    code [
      Markup.keyword "type ";
      params;
      pcdata tyname;
    ] ::
    manifest @
    representation @
    [code constraints]
  in
  Markup.make_spec ~get_package ~id:t.id ~doc tdecl_def

and extension ~get_package (t : _ Types.Extension.t) =
  let doc = Documentation.to_html ~get_package t.doc in
  let extension =
    code (
      Markup.keyword "type " ::
      Html_tree.Relative_link.of_path ~stop_before:false ~get_package t.type_path @
      [ Markup.keyword " += " ]
    ) ::
    list_concat_map t.constructors ~sep:(code [Markup.keyword " | "])
      ~f:(extension_constructor ~get_package)
  in
  (* FIXME: really want to use the kind "extension" here? *)
  (* Inlined [Markup.make_spec] as we don't have an id (which implies we don't
     have an anchor either). *)
  div ~a:[ a_class ["spec"; "extension"] ] [
    div ~a:[ a_class ["def"; "extension"] ] extension;
    div ~a:[ a_class ["doc"] ] doc;
  ]

and extension_constructor ~get_package (t : _ Types.Extension.Constructor.t) =
  (* TODO doc *)
  constructor ~get_package t.id t.args t.res

and exn ~get_package (t : _ Types.Exception.t) =
  let cstr = constructor ~get_package t.id t.args t.res in
  let doc = Documentation.to_html ~get_package t.doc in
  let exn = code [ Markup.keyword "exception " ] :: cstr in
  Markup.make_spec ~get_package ~id:t.id ~doc exn

and te_variant
   : 'inner 'outer. get_package:('a -> string) -> 'a Types.TypeExpr.Variant.t
  -> ('inner, 'outer) text elt list
= fun ~get_package (t : _ Types.TypeExpr.Variant.t) ->
  let elements =
    list_concat_map t.elements ~sep:(pcdata " | ") ~f:(function
      | Types.TypeExpr.Variant.Type te -> type_expr ~get_package te
      | Constructor (name, _bool, args) ->
        let constr = "`" ^ name in
        match args with
        | [] -> [ pcdata constr ]
        | _ ->
          let args =
            list_concat_map args ~sep:(pcdata " * ") ~f:(type_expr ~get_package)
          in
          pcdata (constr ^ " of ") :: args
    )
  in
  match t.kind with
  | Fixed -> pcdata "[ " :: elements @ [pcdata " ]"]
  | Open -> pcdata "[> " :: elements @ [pcdata " ]"]
  | Closed [] -> pcdata "[< " :: elements @ [pcdata " ]"]
  | Closed lst ->
    let constrs = String.concat ~sep:" " lst in
    pcdata "[< " :: elements @ [pcdata (" " ^ constrs ^ " ]")]

and te_object
   : 'inner 'outer. get_package:('a -> string) -> 'a Types.TypeExpr.Object.t
  -> ('inner, 'outer) text elt list
= fun ~get_package (t : _ Types.TypeExpr.Object.t) ->
  let open Types.TypeExpr.Object in
  let fields =
    list_concat_map t.fields ~f:(function
      | Method { name; type_ } ->
        pcdata (name ^ " : ") :: type_expr ~get_package type_ @ [pcdata "; "]
      | Inherit type_ ->
        type_expr ~get_package type_ @ [pcdata "; "]
    )
  in
  pcdata "< " :: fields @ [pcdata ((if t.open_ then ".. " else "") ^ ">")]

and format_type_path
  : 'inner 'outer. get_package:('a -> string) -> delim:[ `parens | `brackets ]
  -> 'a Types.TypeExpr.t list -> ('inner, 'outer) text elt list
  -> ('inner, 'outer) text elt list
= fun ~get_package ~delim params path ->
  match params with
  | [] -> path
  | [param] ->
    type_expr ~needs_parentheses:true ~get_package param @ pcdata " " :: path
  | params  ->
    let params =
      list_concat_map params ~sep:(pcdata ",\194\160")
        ~f:(type_expr ~get_package)
    in
    match delim with
    | `parens   -> pcdata "(" :: params @ pcdata ")\194\160" :: path
    | `brackets -> pcdata "[" :: params @ pcdata "]\194\160" :: path

and type_expr
   : 'inner 'outer. ?needs_parentheses:bool -> get_package:('a -> string)
  -> 'a Types.TypeExpr.t -> ('inner, 'outer) text elt list
= fun ?(needs_parentheses=false) ~get_package t ->
  match t with
  | Var s -> [Markup.Type.var ("'" ^ s)]
  | Any  -> [Markup.Type.var "_"]
  | Alias (te, alias) ->
    type_expr ~needs_parentheses:true ~get_package te @
    Markup.keyword " as " :: [ pcdata alias ]
  | Arrow (None, src, dst) ->
    let res =
      type_expr ~needs_parentheses:true ~get_package src @
      pcdata " " :: Markup.arrow :: pcdata " " :: type_expr ~get_package dst
    in
    if not needs_parentheses then res else pcdata "(" :: res @ [pcdata ")"]
  | Arrow (Some lbl, src, dst) ->
    let res =
      Markup.label lbl @ pcdata ":" ::
      type_expr ~needs_parentheses:true ~get_package src @
      pcdata " " :: Markup.arrow :: pcdata " " :: type_expr ~get_package dst
    in
    if not needs_parentheses then res else pcdata "(" :: res @ [pcdata ")"]
  | Tuple lst ->
    let res =
      list_concat_map lst ~sep:(Markup.keyword " * ")
        ~f:(type_expr ~needs_parentheses:true ~get_package)
    in
    if not needs_parentheses then res else pcdata "(" :: res @ [pcdata ")"]
  | Constr (path, args) ->
    let link = Html_tree.Relative_link.of_path ~stop_before:false ~get_package path in
    format_type_path ~get_package ~delim:(`parens) args link
  | Variant v -> te_variant ~get_package v
  | Object o -> te_object ~get_package o
  | Class (path, args) ->
    format_type_path ~get_package ~delim:(`brackets) args
      (Html_tree.Relative_link.of_path ~stop_before:false ~get_package path)
  | Poly (polyvars, t) ->
    pcdata (String.concat ~sep:" " polyvars ^ ". ") :: type_expr ~get_package t
  | Package pkg ->
    pcdata "(" :: Markup.keyword "module " ::
    Html_tree.Relative_link.of_path ~stop_before:false ~get_package pkg.path @
    begin match pkg.substitutions with
    | [] -> []
    | lst ->
      pcdata " " :: Markup.keyword "with" :: pcdata " " ::
      list_concat_map ~sep:(Markup.keyword " and ") lst
        ~f:(package_subst ~get_package pkg.path)
    end
    @ [pcdata ")"]

and package_subst
   : 'inner 'outer. get_package:('a -> string)
   -> 'a Path.module_type -> 'a Fragment.type_ * 'a Types.TypeExpr.t
   -> ('inner, 'outer) text elt list
   = fun ~get_package pkg_path (frag_typ, te) ->
  Markup.keyword "type " ::
  (match pkg_path with
   | Path.Resolved rp ->
     let base =
       Identifier.signature_of_module_type (Path.Resolved.identifier rp)
     in
     Html_tree.Relative_link.of_fragment ~get_package ~base
       (Fragment.any_sort frag_typ)
   | _ ->
     [ pcdata (Html_tree.render_fragment (Fragment.any_sort frag_typ)) ]) @
  pcdata " " :: Markup.keyword "=" :: pcdata " " ::
  type_expr ~get_package te

and value ~get_package (t : _ Types.Value.t) =
  let name = Identifier.name t.id in
  let doc = Documentation.to_html ~get_package t.doc in
  let value =
    Markup.keyword "val " ::
    pcdata name ::
    pcdata " : " ::
    type_expr ~get_package t.type_
  in
  Markup.make_def ~get_package ~id:t.id ~doc ~code:value

and external_ ~get_package (t : _ Types.External.t) =
  let name = Identifier.name t.id in
  let doc = Documentation.to_html ~get_package t.doc in
  let external_ =
    Markup.keyword "external " ::
    pcdata name ::
    pcdata " : " ::
    type_expr ~get_package t.type_ @
    pcdata " = " ::
    List.map t.primitives ~f:(fun p -> pcdata ("\"" ^ p ^ "\" "))
  in
  Markup.make_def ~get_package ~id:t.id ~doc ~code:external_

and class_signature ~get_package (t : _ Types.ClassSignature.t) =
  (* FIXME: use [t.self] *)
  let recording_doc = ref true in
  List.concat @@ List.map t.items ~f:(function
    | Types.ClassSignature.Method m -> [ method_ ~get_package m ]
    | InstanceVariable v -> [ instance_variable ~get_package v ]
    | Constraint (ty1, ty2) -> format_constraints ~get_package [ty1, ty2]
    | Inherit (Signature _) -> assert false (* Bold. *)
    | Inherit cte ->
      Markup.keyword "inherit " ::
      class_type_expr ~get_package cte
    | Comment (Documentation doc) ->
      if !recording_doc then
        Documentation.to_html ~get_package doc
      else
        []
    | Comment Stop ->
      recording_doc := not !recording_doc;
      []
  )

and method_ ~get_package (t : _ Types.Method.t) =
  let name = Identifier.name t.id in
  let doc = Documentation.to_html ~get_package t.doc in
  let virtual_ = if t.virtual_ then Markup.keyword "virtual " else pcdata "" in
  let private_ = if t.private_ then Markup.keyword "private " else pcdata "" in
  let method_ =
    Markup.keyword "method " ::
    private_ ::
    virtual_ ::
    pcdata name ::
    pcdata " : " ::
    type_expr ~get_package t.type_
  in
  Markup.make_def ~get_package ~id:t.id ~doc ~code:method_

and instance_variable ~get_package (t : _ Types.InstanceVariable.t) =
  let name = Identifier.name t.id in
  let doc = Documentation.to_html ~get_package t.doc in
  let virtual_ = if t.virtual_ then Markup.keyword "virtual " else pcdata "" in
  let mutable_ = if t.mutable_ then Markup.keyword "mutable " else pcdata "" in
  let val_ =
    Markup.keyword "val " ::
    mutable_ ::
    virtual_ ::
    pcdata name ::
    pcdata " : " ::
    type_expr ~get_package t.type_
  in
  Markup.make_def ~get_package ~id:t.id ~doc ~code:val_

and class_type_expr
   : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Types.ClassType.expr
  -> ('inner_row, 'outer_row) text elt list
   = fun ~get_package (cte : _ Types.ClassType.expr) ->
     match cte with
     | Constr (path, args) ->
       let link = Html_tree.Relative_link.of_path ~stop_before:false ~get_package path in
       format_type_path ~get_package ~delim:(`brackets) args link
     | Signature _ ->
       [ Markup.keyword "object" ; pcdata " ... " ; Markup.keyword "end" ]

and class_decl
   : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Types.Class.decl
  -> ('inner_row, 'outer_row) text elt list
  = fun ~get_package (cd : _ Types.Class.decl) ->
    match cd with
    | ClassType expr -> class_type_expr ~get_package expr
    (* TODO: factorize the following with [type_expr] *)
    | Arrow (None, src, dst) ->
      type_expr ~needs_parentheses:true ~get_package src @
      pcdata " " :: Markup.arrow :: pcdata " " :: class_decl ~get_package dst
    | Arrow (Some lbl, src, dst) ->
      Markup.label lbl @ pcdata ":" ::
      type_expr ~needs_parentheses:true ~get_package src @
      pcdata " " :: Markup.arrow :: pcdata " " :: class_decl ~get_package dst

and class_ ~get_package (t : _ Types.Class.t) =
  let name = Identifier.name t.id in
  let params = format_params ~delim:(`brackets) t.params in
  let virtual_ = if t.virtual_ then Markup.keyword "virtual " else pcdata "" in
  let cd = class_decl ~get_package t.type_ in
  let cname, subtree =
    match t.expansion with
    | None -> pcdata name, []
    | Some csig ->
      Html_tree.enter ~kind:(`Class) name;
      let doc = Documentation.to_html ~get_package t.doc in
      let expansion = class_signature ~get_package csig in
      let expansion =
        match doc with
        | [] -> expansion
        | _ -> div ~a:[ a_class ["doc"] ] doc :: expansion
      in
      let subtree = Html_tree.make (expansion, []) in
      Html_tree.leave ();
      a ~a:[ a_href ~kind:`Class name ] [pcdata name], [subtree]
  in
  let class_def_content =
    Markup.keyword "class " ::
    virtual_ ::
    params ::
    cname ::
    pcdata " : " ::
    cd
  in
  let region =
    Markup.make_def ~get_package ~id:t.id ~code:class_def_content
      ~doc:(Documentation.first_to_html ~get_package t.doc)
  in
  [ region ], subtree

and class_type ~get_package (t : _ Types.ClassType.t) =
  let name = Identifier.name t.id in
  let params = format_params ~delim:(`brackets) t.params in
  let virtual_ = if t.virtual_ then Markup.keyword "virtual " else pcdata "" in
  let expr = class_type_expr ~get_package t.expr in
  let cname, subtree =
    match t.expansion with
    | None -> pcdata name, []
    | Some csig ->
      Html_tree.enter ~kind:(`Cty) name;
      let doc = Documentation.to_html ~get_package t.doc in
      let expansion = class_signature ~get_package csig in
      let expansion =
        match doc with
        | [] -> expansion
        | _ -> div ~a:[ a_class ["doc"] ] doc :: expansion
      in
      let subtree = Html_tree.make (expansion, []) in
      Html_tree.leave ();
      a ~a:[ a_href ~kind:`Class name ] [pcdata name], [subtree]
  in
  let ctyp =
    Markup.keyword "class type " ::
    virtual_ ::
    params ::
    cname ::
    pcdata " = " ::
    expr
  in
  let region =
    Markup.make_def ~get_package ~id:t.id ~code:ctyp
      ~doc:(Documentation.first_to_html ~get_package t.doc)
  in
  [ region ], subtree

and include_ ~get_package (t : _ Types.Include.t) =
  let doc = Documentation.to_html ~get_package t.doc in
  let included_html, tree = signature ~get_package t.expansion.content in
  let should_be_inlined, should_be_open =
    match t.doc with
    | Ok { tags ; _ } ->
      let should_be_open =
        let forced_open =
          List.exists tags ~f:(function
            | Types.Documentation.Tag ("open", _) -> true
            | _ -> false
          )
        in
        if forced_open then true else
          !Html_tree.open_details && List.for_all tags ~f:(function
            | Types.Documentation.Tag ("closed", _) -> false
            | _ -> true
          )
      in
      List.mem Types.Documentation.Inline ~set:tags, should_be_open
    | _ -> false, !Html_tree.open_details
  in
  let incl =
    if should_be_inlined then
      included_html
    else
      let incl =
        code (
          Markup.keyword "include " ::
          module_decl' ~get_package t.parent t.decl
        )
      in
      (* FIXME: I'd like to add an anchor here, but I don't know what id to give
         it... *)
      [ details ~a:(if should_be_open then [a_open ()] else [])
          (Markup.def_summary [incl]) included_html
      ]
  in
  [ div ~a:[ a_class ["spec"; "include"] ]
      (div ~a:[ a_class ["doc"] ] doc :: incl)
  ], tree

let page ~get_package (t : _ Types.Page.t) : Html_tree.t =
  let package, name =
    match t.name with
    | Paths.Identifier.Page (a, name) -> get_package a, name
  in
  Html_tree.enter package;
  Html_tree.enter ~kind:`Page name;
  let html = Documentation.to_html ~get_package t.content in
  Html_tree.make (html, [])

