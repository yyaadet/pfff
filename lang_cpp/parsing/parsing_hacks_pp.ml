(* Yoann Padioleau
 *
 * Copyright (C) 2002-2008 Yoann Padioleau
 * Copyright (C) 2011 Facebook
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License (GPL)
 * version 2 as published by the Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * file license.txt for more details.
 *)

open Common

module Flag = Flag_parsing_cpp
module Ast = Ast_cpp

module TH = Token_helpers_cpp
module LP = Lexer_parser_cpp
module Parser = Parser_cpp

open Parser_cpp
open Token_views_cpp

open Parsing_hacks_lib

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* the pair is the status of '()' and '{}', ex: (-1,0) 
 * if too much ')' and good '{}' 
 * could do for [] too ? 
 * could do for ','   if encounter ',' at "toplevel", not inside () or {}
 * then if have ifdef, then certainly can lead to a problem.
 *)
let (count_open_close_stuff_ifdef_clause: ifdef_grouped list -> (int * int)) = 
 fun xs -> 
   let cnt_paren, cnt_brace = ref 0, ref 0 in
   xs +> iter_token_ifdef (fun x -> 
     (match x.tok with
     | x when TH.is_opar x  -> incr cnt_paren
     | x when TH.is_obrace x -> incr cnt_brace
     | x when TH.is_cpar x  -> decr cnt_paren
     | x when TH.is_obrace x -> decr cnt_brace
     | _ -> ()
     )
   );
   !cnt_paren, !cnt_brace

(* ------------------------------------------------------------------------- *)
(* cppext: *)

let forLOOKAHEAD = 30
  
(* look if there is a '{' just after the closing ')', and handling the
 * possibility to have nested expressions inside nested parenthesis 
 *)
let rec is_really_foreach xs = 
  let rec is_foreach_aux = function
    | [] -> false, []
    | TCPar _::TOBrace _::xs -> true, xs
      (* the following attempts to handle the cases where there is a
	 single statement in the body of the loop.  undoubtedly more
	 cases are needed. 
         todo: premier(statement) - suivant(funcall)
      *)
    | TCPar _::TIdent _::xs -> true, xs
    | TCPar _::Tif _::xs -> true, xs
    | TCPar _::Twhile _::xs -> true, xs
    | TCPar _::Tfor _::xs -> true, xs
    | TCPar _::Tswitch _::xs -> true, xs

    | TCPar _::xs -> false, xs
    | TOPar _::xs -> 
        let (_, xs') = is_foreach_aux xs in
        is_foreach_aux xs'
    | x::xs -> is_foreach_aux xs
  in
  is_foreach_aux xs +> fst


(* TODO: set_ifdef_parenthize_info ?? from parsing_c/ *)


(*****************************************************************************)
(* CPP handling: macros, ifdefs, macros defs  *)
(*****************************************************************************)

(* ------------------------------------------------------------------------- *)
(* ifdef keeping/passing *)
(* ------------------------------------------------------------------------- *)

(* #if 0, #if 1,  #if LINUX_VERSION handling *)
let rec find_ifdef_bool xs = 
  xs +> List.iter (function 
  | NotIfdefLine _ -> ()
  | Ifdefbool (is_ifdef_positif, xxs, info_ifdef_stmt) -> 
      
      if is_ifdef_positif
      then pr2_pp "commenting parts of a #if 1 or #if LINUX_VERSION"
      else pr2_pp "commenting a #if 0 or #if LINUX_VERSION or __cplusplus";

      (match xxs with
      | [] -> raise Impossible
      | firstclause::xxs -> 
          info_ifdef_stmt +> List.iter (set_as_comment Token_cpp.CppDirective);
            
          if is_ifdef_positif
          then xxs +> List.iter 
            (iter_token_ifdef (set_as_comment Token_cpp.CppOther))
          else begin
            firstclause +> iter_token_ifdef (set_as_comment Token_cpp.CppOther);
            (match List.rev xxs with
            (* keep only last *)
            | last::startxs -> 
                startxs +> List.iter 
                  (iter_token_ifdef (set_as_comment Token_cpp.CppOther))
            | [] -> (* not #else *) ()
            );
          end
      );
      
  | Ifdef (xxs, info_ifdef_stmt) -> xxs +> List.iter find_ifdef_bool
  )



let thresholdIfdefSizeMid = 6

(* infer ifdef involving not-closed expressions/statements *)
let rec find_ifdef_mid xs = 
  xs +> List.iter (function 
  | NotIfdefLine _ -> ()
  | Ifdef (xxs, info_ifdef_stmt) -> 
      (match xxs with 
      | [] -> raise Impossible
      | [first] -> ()
      | first::second::rest -> 
          (* don't analyse big ifdef *)
          if xxs +> List.for_all 
            (fun xs -> List.length xs <= thresholdIfdefSizeMid) && 
            (* don't want nested ifdef *)
            xxs +> List.for_all (fun xs -> 
              xs +> List.for_all 
                (function NotIfdefLine _ -> true | _ -> false)
            )
            
          then 
            let counts = xxs +> List.map count_open_close_stuff_ifdef_clause in
            let cnt1, cnt2 = List.hd counts in 
            if cnt1 <> 0 || cnt2 <> 0 && 
               counts +> List.for_all (fun x -> x = (cnt1, cnt2))
              (*
                if counts +> List.exists (fun (cnt1, cnt2) -> 
                cnt1 <> 0 || cnt2 <> 0 
                ) 
              *)
            then begin
              pr2_pp "found ifdef-mid-something";
              (* keep only first, treat the rest as comment *)
              info_ifdef_stmt +> List.iter (set_as_comment Token_cpp.CppDirective);
              (second::rest) +> List.iter 
                (iter_token_ifdef (set_as_comment Token_cpp.CppOther));
            end
              
      );
      List.iter find_ifdef_mid xxs
        
  (* no need complex analysis for ifdefbool *)
  | Ifdefbool (_, xxs, info_ifdef_stmt) -> 
      List.iter find_ifdef_mid xxs
  )


let thresholdFunheaderLimit = 4

(* ifdef defining alternate function header, type *)
let rec find_ifdef_funheaders = function
  | [] -> ()
  | NotIfdefLine _::xs -> find_ifdef_funheaders xs 

  (* ifdef-funheader if ifdef with 2 lines and a '{' in next line *)
  | Ifdef 
      ([(NotIfdefLine (({col = 0} as _xline1)::line1))::ifdefblock1;
        (NotIfdefLine (({col = 0} as xline2)::line2))::ifdefblock2
      ], info_ifdef_stmt 
      )
    ::NotIfdefLine (({tok = TOBrace i; col = 0})::line3)
    ::xs  
   when List.length ifdefblock1 <= thresholdFunheaderLimit &&
        List.length ifdefblock2 <= thresholdFunheaderLimit
    -> 
      find_ifdef_funheaders xs;
      info_ifdef_stmt +> List.iter (set_as_comment Token_cpp.CppDirective);
      let all_toks = [xline2] @ line2 in
      all_toks +> List.iter (set_as_comment Token_cpp.CppOther) ;
      ifdefblock2 +> iter_token_ifdef (set_as_comment Token_cpp.CppOther);

  (* ifdef with nested ifdef *)
  | Ifdef 
      ([[NotIfdefLine (({col = 0} as _xline1)::line1)];
        [Ifdef 
            ([[NotIfdefLine (({col = 0} as xline2)::line2)];
              [NotIfdefLine (({col = 0} as xline3)::line3)];
            ], info_ifdef_stmt2
            )
        ]
      ], info_ifdef_stmt 
      )
    ::NotIfdefLine (({tok = TOBrace i; col = 0})::line4)
    ::xs  
    -> 
      find_ifdef_funheaders xs;
      info_ifdef_stmt  +> List.iter (set_as_comment Token_cpp.CppDirective);
      info_ifdef_stmt2 +> List.iter (set_as_comment Token_cpp.CppDirective);
      let all_toks = [xline2;xline3] @ line2 @ line3 in
      all_toks +> List.iter (set_as_comment Token_cpp.CppOther);

 (* ifdef with elseif *)
  | Ifdef 
      ([[NotIfdefLine (({col = 0} as _xline1)::line1)];
        [NotIfdefLine (({col = 0} as xline2)::line2)];
        [NotIfdefLine (({col = 0} as xline3)::line3)];
      ], info_ifdef_stmt 
      )
    ::NotIfdefLine (({tok = TOBrace i; col = 0})::line4)
    ::xs 
    -> 
      find_ifdef_funheaders xs;
      info_ifdef_stmt +> List.iter (set_as_comment Token_cpp.CppDirective);
      let all_toks = [xline2;xline3] @ line2 @ line3 in
      all_toks +> List.iter (set_as_comment Token_cpp.CppOther)
        

  | Ifdef (xxs,info_ifdef_stmt)::xs 
  | Ifdefbool (_, xxs,info_ifdef_stmt)::xs -> 
      List.iter find_ifdef_funheaders xxs; 
      find_ifdef_funheaders xs


let rec adjust_inifdef_include xs = 
  xs +> List.iter (function 
  | NotIfdefLine _ -> ()
  | Ifdef (xxs, info_ifdef_stmt) | Ifdefbool (_, xxs, info_ifdef_stmt) -> 
      xxs +> List.iter (iter_token_ifdef (fun tokext -> 
        match tokext.tok with
        | Parser.TInclude (s1, s2, inifdef_ref, ii) -> 
            inifdef_ref := true;
        | _ -> ()
      ));
  )


(* ------------------------------------------------------------------------- *)
(* cpp-builtin part2, macro, using standard.h or other defs *)
(* ------------------------------------------------------------------------- *)

(* now in cpp_token_c.ml *) 

(* ------------------------------------------------------------------------- *)
(* stringification *)
(* ------------------------------------------------------------------------- *)

let rec find_string_macro_paren xs = 
  match xs with
  | [] -> ()
  | Parenthised(xxs, info_parens)::xs -> 
      xxs +> List.iter (fun xs -> 
        if xs +> List.exists 
          (function PToken({tok = TString _}) -> true | _ -> false) &&
          xs +> List.for_all 
          (function PToken({tok = TString _}) | PToken({tok = TIdent _}) -> 
            true | _ -> false)
        then
          xs +> List.iter (fun tok -> 
            match tok with
            | PToken({tok = TIdent (s,_)} as id) -> 
                msg_stringification s;
                id.tok <- TMacroString (TH.info_of_tok id.tok);
            | _ -> ()
          )
        else 
          find_string_macro_paren xs
      );
      find_string_macro_paren xs
  | PToken(tok)::xs -> 
      find_string_macro_paren xs
      

(* ------------------------------------------------------------------------- *)
(* macro2 *)
(* ------------------------------------------------------------------------- *)

(* don't forget to recurse in each case.
 * note that the code below is called after the ifdef phase simplification, 
 * so if this previous phase is buggy, then it may pass some code that
 * could be matched by the following rules but will not. 
 **)
let rec find_macro_paren xs = 
  match xs with
  | [] -> ()
      
  (* attribute *)
  | PToken ({tok = Tattribute _} as id)
    ::Parenthised (xxs,info_parens)
    ::xs
     -> 
      pr2_pp ("MACRO: __attribute detected ");
      [Parenthised (xxs, info_parens)] +> 
        iter_token_paren (set_as_comment Token_cpp.CppAttr);
      set_as_comment Token_cpp.CppAttr id;
      find_macro_paren xs

  (* stringification
   * 
   * the order of the matching clause is important
   * 
   *)

  (* string macro with params, before case *)
  | PToken ({tok = TString _})::PToken ({tok = TIdent (s,_)} as id)
    ::Parenthised (xxs, info_parens)
    ::xs -> 
      pr2_pp ("MACRO: string-macro with params : " ^ s);
      id.tok <- TMacroString (TH.info_of_tok id.tok);
      [Parenthised (xxs, info_parens)] +> 
        iter_token_paren (set_as_comment Token_cpp.CppMacro);
      find_macro_paren xs

  (* after case *)
  | PToken ({tok = TIdent (s,_)} as id)
    ::Parenthised (xxs, info_parens)
    ::PToken ({tok = TString _})
    ::xs -> 
      pr2_pp ("MACRO: string-macro with params : " ^ s);
      id.tok <- TMacroString (TH.info_of_tok id.tok);
      [Parenthised (xxs, info_parens)] +> 
        iter_token_paren (set_as_comment Token_cpp.CppMacro);
      find_macro_paren xs


  (* for the case where the string is not inside a funcall, but
   * for instance in an initializer.
   *)
        
  (* string macro variable, before case *)
  | PToken ({tok = TString ((str,_),_)})::PToken ({tok = TIdent (s,_)} as id)
      ::xs -> 

      (* c++ext: *)
      if str <> "C" then begin

      msg_stringification s;
      id.tok <- TMacroString (TH.info_of_tok id.tok);
      find_macro_paren xs
      end
      (* bugfix, forgot to recurse in else case too ... *)
      else 
        find_macro_paren xs

  (* after case *)
  | PToken ({tok = TIdent (s,_)} as id)::PToken ({tok = TString _})
      ::xs -> 
      msg_stringification s;
      id.tok <- TMacroString (TH.info_of_tok id.tok);
      find_macro_paren xs



  (* cooperating with standard.h *)
  | PToken ({tok = TIdent (s,i1)} as id)::xs 
      when s = "MACROSTATEMENT" -> 
      id.tok <- TMacroStmt(TH.info_of_tok id.tok);
      find_macro_paren xs
        


  (* recurse *)
  | (PToken x)::xs -> find_macro_paren xs 
  | (Parenthised (xxs, info_parens))::xs -> 
      xxs +> List.iter find_macro_paren;
      find_macro_paren xs





(* don't forget to recurse in each case *)
let rec find_macro_lineparen xs = 
  match xs with
  | [] -> ()

  (* firefoxext: ex: NS_DECL_NSIDOMNODELIST *)
  | (Line ([PToken ({tok = TIdent (s,_)} as macro);]))::xs 
      when s ==~ regexp_ns_decl_like -> 
      
      msg_declare_macro s;
      set_as_comment Token_cpp.CppMacro macro;
      
      find_macro_lineparen (xs)

  (* firefoxext: ex: NS_DECL_NSIDOMNODELIST; *)
  | (Line ([PToken ({tok = TIdent (s,_)} as macro);
            PToken ({tok = TPtVirg _})]))::xs 
      when s ==~ regexp_ns_decl_like -> 
      
      msg_declare_macro s;
      set_as_comment Token_cpp.CppMacro macro;
      
      find_macro_lineparen (xs)

  (* firefoxext: ex: NS_IMPL_XXX(a) *)
  | (Line ([PToken ({tok = TIdent (s,_)} as macro);
           Parenthised (xxs,info_parens);
          ]))
    ::xs 
      when s ==~ regexp_ns_decl_like -> 
     
      msg_declare_macro s;

      [Parenthised (xxs, info_parens)] +> 
        iter_token_paren (set_as_comment Token_cpp.CppMacro);
      set_as_comment Token_cpp.CppMacro macro;
      
      find_macro_lineparen (xs)


  (* linuxext: ex: static [const] DEVICE_ATTR(); *)
  | (Line 
        (
          [PToken ({tok = Tstatic _});
           PToken ({tok = TIdent (s,_)} as macro);
           Parenthised (xxs,info_parens);
           PToken ({tok = TPtVirg _});
          ] 
        ))
    ::xs 
    when (s ==~ regexp_macro) -> 
      msg_declare_macro s;
      let info = TH.info_of_tok macro.tok in
      macro.tok <- TMacroDecl (Ast.str_of_info info, info);

      find_macro_lineparen (xs)

  (* the static const case *)
  | (Line 
        (
          [PToken ({tok = Tstatic _});
           PToken ({tok = Tconst _} as const);
           PToken ({tok = TIdent (s,_)} as macro);
           Parenthised (xxs,info_parens);
           PToken ({tok = TPtVirg _});
          ] 
            (*as line1*)

        ))
    ::xs 
    when (s ==~ regexp_macro) -> 
      msg_declare_macro s;
      let info = TH.info_of_tok macro.tok in
      macro.tok <- TMacroDecl (Ast.str_of_info info, info);
      
      (* need retag this const, otherwise ambiguity in grammar 
         21: shift/reduce conflict (shift 121, reduce 137) on Tconst
  	 decl2 : Tstatic . TMacroDecl TOPar argument_list TCPar ...
	 decl2 : Tstatic . Tconst TMacroDecl TOPar argument_list TCPar ...
	 storage_class_spec : Tstatic .  (137)
      *)
      const.tok <- TMacroDeclConst (TH.info_of_tok const.tok);

      find_macro_lineparen (xs)


  (* same but without trailing ';'
   * 
   * I do not put the final ';' because it can be on a multiline and
   * because of the way mk_line is coded, we will not have access to
   * this ';' on the next line, even if next to the ')' *)
  | (Line 
        ([PToken ({tok = Tstatic _});
          PToken ({tok = TIdent (s,_)} as macro);
          Parenthised (xxs,info_parens);
        ] 
        ))
    ::xs 
    when s ==~ regexp_macro -> 

      msg_declare_macro s;
      let info = TH.info_of_tok macro.tok in
      macro.tok <- TMacroDecl (Ast.str_of_info info, info);

      find_macro_lineparen (xs)




  (* on multiple lines *)
  | (Line 
        (
          (PToken ({tok = Tstatic _})::[]
          )))
    ::(Line 
          (
            [PToken ({tok = TIdent (s,_)} as macro);
             Parenthised (xxs,info_parens);
             PToken ({tok = TPtVirg _});
            ]
          ) 
        )
    ::xs 
    when (s ==~ regexp_macro) -> 
      msg_declare_macro s;
      let info = TH.info_of_tok macro.tok in
      macro.tok <- TMacroDecl (Ast.str_of_info info, info);

      find_macro_lineparen (xs)


  (* linuxext: ex: DECLARE_BITMAP(); 
   * 
   * Here I use regexp_declare and not regexp_macro because
   * Sometimes it can be a FunCallMacro such as DEBUG(foo());
   * Here we don't have the preceding 'static' so only way to
   * not have positive is to restrict to .*DECLARE.* macros.
   *
   * but there is a grammar rule for that, so don't need this case anymore
   * unless the parameter of the DECLARE_xxx are wierd and can not be mapped
   * on a argument_list
   *)
        
  | (Line 
        ([PToken ({tok = TIdent (s,_)} as macro);
          Parenthised (xxs,info_parens);
          PToken ({tok = TPtVirg _});
        ]
        ))
    ::xs 
    when (s ==~ regexp_declare) -> 

      msg_declare_macro s;
      let info = TH.info_of_tok macro.tok in
      macro.tok <- TMacroDecl (Ast.str_of_info info, info);

      find_macro_lineparen (xs)

        
  (* toplevel macros.
   * module_init(xxx)
   * 
   * Could also transform the TIdent in a TMacroTop but can have false
   * positive, so easier to just change the TCPar and so just solve
   * the end-of-stream pb of ocamlyacc
   *)
  | (Line 
        ([PToken ({tok = TIdent (s,ii); col = col1; where = ctx} as _macro);
          Parenthised (xxs,info_parens);
        ] as _line1
        ))
    ::xs when col1 = 0
    -> 
      let condition = 
        (* to reduce number of false positive *)
        (match xs with
        | (Line (PToken ({col = col2 } as other)::restline2))::_ -> 
            TH.is_eof other.tok || (col2 = 0 &&
             (match other.tok with
             | TOBrace _ -> false (* otherwise would match funcdecl *)
             | TCBrace _ when ctx <> InFunction -> false
             | TPtVirg _ 
             | TCol _
               -> false
             | tok when TH.is_binary_operator tok -> false
                 
             | _ -> true
             )
            )
        | _ -> false
        )
      in
      if condition
      then begin
          msg_macro_toplevel_noptvirg s;
          (* just to avoid the end-of-stream pb of ocamlyacc  *)
          let tcpar = Common.list_last info_parens in
          tcpar.tok <- TCParEOL (TH.info_of_tok tcpar.tok);
          
          (*macro.tok <- TMacroTop (s, TH.info_of_tok macro.tok);*)
          
        end;

       find_macro_lineparen (xs)



  (* macro with parameters 
   * ex: DEBUG()
   *     return x;
   *)
  | (Line 
        ([PToken ({tok = TIdent (s,ii); col = col1; where = ctx} as macro);
          Parenthised (xxs,info_parens);
        ] as _line1
        ))
    ::(Line 
          (PToken ({col = col2 } as other)::restline2
          ) as line2)
    ::xs 
    (* when s ==~ regexp_macro *)
    -> 
      let condition = 
        (col1 = col2 && 
            (match other.tok with
            | TOBrace _ -> false (* otherwise would match funcdecl *)
            | TCBrace _ when ctx <> InFunction -> false
            | TPtVirg _ 
            | TCol _
                -> false
            | tok when TH.is_binary_operator tok -> false

            | _ -> true
            )
        ) 
        || 
        (col2 <= col1 &&
              (match other.tok with
              | TCBrace _ when ctx = InFunction -> true
              | Treturn _ -> true
              | Tif _ -> true
              | Telse _ -> true

              | _ -> false
              )
          )

      in
      
      if condition
      then 
        if col1 = 0 then ()
        else begin
          msg_macro_noptvirg s;
          macro.tok <- TMacroStmt (TH.info_of_tok macro.tok);
          [Parenthised (xxs, info_parens)] +> 
            iter_token_paren (set_as_comment Token_cpp.CppMacro);
        end;

      find_macro_lineparen (line2::xs)
        
  (* linuxext:? single macro 
   * ex: LOCK
   *     foo();
   *     UNLOCK
   *)
  | (Line 
        ([PToken ({tok = TIdent (s,ii); col = col1; where = ctx} as macro);
        ] as _line1
        ))
    ::(Line 
          (PToken ({col = col2 } as other)::restline2
          ) as line2)
    ::xs -> 
    (* when s ==~ regexp_macro *)
      
      let condition = 
        (col1 = col2 && 
            col1 <> 0 && (* otherwise can match typedef of fundecl*)
            (match other.tok with
            | TPtVirg _ -> false 
            | TOr _ -> false 
            | TCBrace _ when ctx <> InFunction -> false
            | tok when TH.is_binary_operator tok -> false

            | _ -> true
            )) ||
          (col2 <= col1 &&
              (match other.tok with
              | TCBrace _ when ctx = InFunction -> true
              | Treturn _ -> true
              | Tif _ -> true
              | Telse _ -> true
              | _ -> false
              ))
      in
      
      if condition
      then begin
        msg_macro_noptvirg_single s;
        macro.tok <- TMacroStmt (TH.info_of_tok macro.tok);
      end;
      find_macro_lineparen (line2::xs)
        
  | x::xs -> 
      find_macro_lineparen xs


(* ------------------------------------------------------------------------- *)
(* define tobrace init *)
(* ------------------------------------------------------------------------- *)

let rec find_define_init_brace_paren xs = 
 let rec aux xs = 
  match xs with
  | [] -> ()

  (* mainly for firefox *)
  | (PToken {tok = TDefine _})
    ::(PToken {tok = TIdentDefine (s,_)})
    ::(PToken ({tok = TOBrace i1} as tokbrace))
    ::(PToken tok2)
    ::(PToken tok3)
    ::xs -> 
      let is_init =
        match tok2.tok, tok3.tok with
        | TInt _, TComma _ -> true
        | TString _, TComma _ -> true
        | TIdent _, TComma _ -> true
        | _ -> false
            
      in
      if is_init
      then begin 
        pr2_pp("found define initializer: " ^s);
        tokbrace.tok <- TOBraceDefineInit i1;
      end;

      aux xs

  (* mainly for linux, especially in sound/ *)
  | (PToken {tok = TDefine _})
    ::(PToken {tok = TIdentDefine (s,_)})
    ::(Parenthised(xxx, info_parens))
    ::(PToken ({tok = TOBrace i1} as tokbrace))
    ::(PToken tok2)
    ::(PToken tok3)
    ::xs -> 
      let is_init =
        match tok2.tok, tok3.tok with
        | TInt _, TComma _ -> true
        | TDot _, TIdent _ -> true
        | TIdent _, TComma _ -> true
        | _ -> false
            
      in
      if is_init
      then begin 
        pr2_pp("found define initializer with param: " ^ s);
        tokbrace.tok <- TOBraceDefineInit i1;
      end;

      aux xs

  (* recurse *)
  | (PToken x)::xs -> aux xs 
  | (Parenthised (xxs, info_parens))::xs -> 
      (* not need for tobrace init:
       *  xxs +> List.iter aux; 
       *)
      aux xs
 in
 aux xs

(* ------------------------------------------------------------------------- *)
(* action *)
(* ------------------------------------------------------------------------- *)

let rec find_actions = function
  | [] -> ()

  | PToken ({tok = TIdent (s,ii)})
    ::Parenthised (xxs,info_parens)
    ::xs -> 
      find_actions xs;
      xxs +> List.iter find_actions;
      let modified = find_actions_params xxs in
      if modified 
      then msg_macro_higher_order s
        
  | x::xs -> 
      find_actions xs

and find_actions_params xxs = 
  xxs +> List.fold_left (fun acc xs -> 
    let toks = tokens_of_paren xs in
    if toks +> List.exists (fun x -> TH.is_statement x.tok)
    then begin
      xs +> iter_token_paren (fun x -> 
        if TH.is_eof x.tok
        then 
          (* certainly because paren detection had a pb because of
           * some ifdef-exp
           *)
          pr2 "PB: wierd, I try to tag an EOF token as action"
        else 
          x.tok <- TAction (TH.info_of_tok x.tok);
      );
      true (* modified *)
    end
    else acc
  ) false


