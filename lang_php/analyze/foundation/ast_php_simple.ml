(* Julien Verlaguet
 *
 * Copyright (C) 2011 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
 * A (real) Abstract Syntax Tree for PHP, not a Concrete Syntax Tree as
 * in ast_php.ml
 * 
 * This file contains a simplified version of the PHP abstract syntax
 * tree. The original PHP syntax tree is good for code refactoring;
 * the type used is very precise, However, for other algorithms, 
 * the nature of the AST makes the code a bit redondant.
 * Say I want to write a typer, I need to write a specific version for
 * static expressions, when really, the typer should do the same thing.
 * The same is true for a pretty-printer, topological sort etc ...
 * Hence the idea of a SimpleAST. Which is the original AST where
 * the specialised constructions have been factored back together.
 *)

(*****************************************************************************)
(* The AST related types *)
(*****************************************************************************)

(* to get position information for certain elemenents in the AST *)
type 'a wrap = 'a * Ast_php.tok

type program = stmt list

and stmt =
  (* todo? remove? this is better handled in ast_pp.ml no? *)
  | Comment of string | Newline

  | Expr of expr

  (* pad: Noop could be Block [], but it's abused right now for debugging
   * purpose in the abstract interpreter
   *)
  | Noop
  | Block of stmt list

  | If of expr * stmt * stmt
  | Switch of expr * case list

  | While of expr * stmt list
  | Do of stmt list * expr
  | For of expr list * expr list * expr list * stmt list
  | Foreach of expr * expr * expr option * stmt list

  | Return of expr option
  | Break of expr option
  | Continue of expr option

  | Throw of expr
  | Try of stmt list * catch * catch list

  | InlineHtml of string

  (* only at toplevel in most of our code *)
  | ClassDef of class_def
  | FuncDef of func_def

  | StaticVars of (string wrap * expr option) list
  | Global of expr list

  and case =
    | Case of expr * stmt list
    | Default of stmt list

  (* catch(Exception $exn) { ... } => ("Exception", "$exn", [...]) *)
  and catch = string  * string * stmt list

and expr =
  | Int of string
  | Double of string

  | String of string
  | Guil of encaps list
  | HereDoc of string * encaps list * string

  (* valid for entities (functions, classes, constants) and variables, so
   * can have Id "foo" and Id "$foo"
   *)
  | Id of string wrap

  | Array_get of expr * expr option

  (* often transformed in Id "$this" in the analysis *)
  | This
  (* e.g. Obj_get(Id "$o", Id "foo") when $o->foo *)
  | Obj_get of expr * expr
  (* e.g. Class_get(Id "A", Id "foo") when a::foo
   * (can contain "self", "parent", "static")
   *)
  | Class_get of expr * expr

  | Assign of Ast_php.binaryOp option * expr * expr
  | Infix of Ast_php.fixOp * expr
  | Postfix of Ast_php.fixOp * expr
  | Binop of Ast_php.binaryOp * expr * expr
  | Unop of Ast_php.unaryOp * expr

  | Call of expr * expr list

  | Ref of expr

  | Xhp of xml
  | ConsArray of array_value list
  | List of expr list

  | New of expr * expr list
  | InstanceOf of expr * expr

  | CondExpr of expr * expr * expr
  | Cast of Ast_php.ptype * expr

  | Lambda of func_def

  and array_value =
    | Aval of expr
    | Akval of expr * expr

  and encaps =
    | EncapsString of string
    | EncapsVar of expr
    | EncapsCurly of expr
    | EncapsDollarCurly of expr
    | EncapsExpr of expr

  and xhp =
    | XhpText of string
    | XhpExpr of expr
    | XhpXml of xml

    and xml = {
      xml_tag: string list;
      xml_attrs: (string * xhp_attr) list;
      xml_body: xhp list;
    }

      and xhp_attr =
        | AttrString of encaps list
        | AttrExpr of expr


and func_def = {
  f_ref: bool;
  f_name: string wrap;
  f_params: parameter list;
  f_return_type: hint_type option;
  f_body: stmt list;
}

   and parameter = {
     p_type: hint_type option;
     p_ref: bool;
     p_name: string wrap;
     p_default: expr option;
   }

   and hint_type =
     | Hint of string
     | HintArray


and class_def = {
  c_type: class_type;
  c_name: string wrap;
  c_extends: string list; (* pad: ?? *)
  c_implements: string list;
  c_constants: (string * expr) list;
  c_variables: class_vars list;
  c_body: method_def list;
}

  and class_type =
    | ClassRegular
    | ClassFinal
    | ClassAbstract
    | Interface
    | Trait

  and class_vars = {
    cv_final: bool;
    cv_static: bool;
    cv_abstract: bool;
    cv_visibility: visibility;
    cv_type: hint_type option;
    cv_vars: (string * expr option) list;
  }

  and method_def = {
    m_visibility: visibility;
    m_static: bool;
    m_final: bool;
    m_abstract: bool;
    m_ref: bool;
    m_name: string wrap;
    m_params: parameter list;
    m_return_type: hint_type option;
    m_body: stmt list;
  }

   and visibility =
     | Novis
     | Public  | Private
     | Protected | Abstract

 (* with tarzan *)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let unwrap x = fst x
let wrap s = s, Ast_php.fakeInfo s

let has_modifier cv =
  cv.cv_final ||
  cv.cv_static ||
  cv.cv_abstract ||
  cv.cv_visibility <> Novis

let rec is_string_key = function
  | [] -> true
  | Aval _ :: _ -> false
  | Akval (String _, _) :: rl -> is_string_key rl
  | _ -> false

let rec key_length_acc c = function
  | Aval _ -> c
  | Akval (String s, _) -> max (String.length s + 2) c
  | _ -> c

let key_length l =
  List.fold_left key_length_acc 0 l