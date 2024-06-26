%%% Copyright (C) 2017  Tomas Abrahamsson
%%%
%%% Author: Tomas Abrahamsson <tab@lysator.liu.se>
%%%
%%% This library is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU Lesser General Public
%%% License as published by the Free Software Foundation; either
%%% version 2.1 of the License, or (at your option) any later version.
%%%
%%% This library is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% Lesser General Public License for more details.
%%%
%%% You should have received a copy of the GNU Lesser General Public
%%% License along with this library; if not, write to the Free Software
%%% Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
%%% MA  02110-1301  USA

%%% @doc Generation of encoding functions.
%%% @private

-module(gpb_gen_encoders).

-export([format_exports/2]).
-export([format_encoders_top_function/3]).
-export([format_msg_encoders/4]).
-export([format_map_encoders/4]).
-export([format_aux_encoders/3]).
-export([format_aux_common_encoders/3]).

-include("../include/gpb.hrl").
-include("gpb_codegen.hrl").
-include("gpb_compile.hrl").

-import(gpb_lib, [replace_term/2, replace_tree/2,
                  splice_trees/2, repeat_clauses/2]).

%% -- exports -----------------------------------------------------

format_exports(Defs, Opts) ->
    DoNif = proplists:get_bool(nif, Opts),
    [case gpb_lib:get_records_or_maps_by_opts(Opts) of
         records ->
             ?f("-export([encode_msg/1, encode_msg/2, encode_msg/3]).~n");
         maps ->
             ?f("-export([encode_msg/2, encode_msg/3]).~n")
     end,
     [[?f("-export([encode/1]). %% epb compatibility~n"),
       [?f("-export([~p/1]).~n", [gpb_lib:mk_fn(encode_, MsgName)])
        || {{msg,MsgName}, _Fields} <- Defs],
       "\n"]
      || gpb_lib:get_epb_functions_by_opts(Opts)],
     [[[begin
            NoWrapperFnName = gpb_lib:mk_fn(encode_msg_, MsgName),
            if DoNif ->
                    ?f("-export([~p/1]).~n", [NoWrapperFnName]);
               not DoNif ->
                    ?f("-export([~p/1, ~p/2]).~n",
                       [NoWrapperFnName, NoWrapperFnName])
            end
        end
        || {{msg,MsgName}, _Fields} <- Defs],
       "\n"]
      || gpb_lib:get_bypass_wrappers_by_opts(Opts)]].

%% -- encoders -----------------------------------------------------

format_encoders_top_function(Defs, AnRes, Opts) ->
    case gpb_lib:contains_messages(Defs) of
        true  -> format_encoders_top_function_msgs(Defs, AnRes, Opts);
        false -> format_encoders_top_function_no_msgs(Opts)
    end.

format_encoders_top_function_no_msgs(Opts) ->
    Mapping = gpb_lib:get_records_or_maps_by_opts(Opts),
    [[[?f("-spec encode_msg(_) -> no_return().~n", []),
       gpb_codegen:format_fn(
         encode_msg,
         fun(Msg) ->
                 encode_msg(Msg, dummy_name, [])
         end)] || Mapping == records],
     ?f("-spec encode_msg(_,_) -> no_return().~n", []),
     gpb_codegen:format_fn(
       encode_msg,
       fun(Msg, MsgName) when is_atom(MsgName) ->
               encode_msg(Msg, MsgName, []);
          ('Msg', Opts) when tuple_size('Msg') >= 1, is_list(Opts) ->
               encode_msg('Msg', element(1,'Msg'), [])
       end,
       [repeat_clauses('Msg', [[replace_tree('Msg', ?expr(Msg))]
                               || Mapping == records])]),
     ?f("-spec encode_msg(_,_,_) -> no_return().~n", []),
     gpb_codegen:format_fn(
       encode_msg,
       fun(_Msg, _MsgName, _Opts) ->
               erlang:error({gpb_error, no_messages})
       end),
     [[?f("%% epb compatibility\n"),
       ?f("-spec encode(_) -> no_return().\n"),
       gpb_codegen:format_fn(
         encode,
         fun(_Msg) -> erlang:error({gpb_error, no_messages}) end)]
      || gpb_lib:get_epb_functions_by_opts(Opts)]].

format_encoders_top_function_msgs(Defs, AnRes, Opts) ->
    Verify = proplists:get_value(verify, Opts, optionally),
    Mapping = gpb_lib:get_records_or_maps_by_opts(Opts),
    MsgType = "'$msg'()",
    MsgNamesType = "'$msg_name'()",
    OrList = case Mapping of
                 records -> " | list()";
                 maps -> ""
             end,
    DoNif = proplists:get_bool(nif, Opts),
    [[[gpb_lib:no_underspecs_dialyzer_attr(encode_msg, 1, Opts),
       ?f("-spec encode_msg(~s) -> ~s.~n",
          [MsgType, ret_type_all_msgs(Defs)]),
       gpb_codegen:format_fn(
         encode_msg,
         fun(Msg) when tuple_size(Msg) >= 1 ->
                 encode_msg(Msg, element(1, Msg), [])
         end)] || Mapping == records],
     gpb_lib:no_underspecs_dialyzer_attr(encode_msg, 2, Opts),
     ?f("-spec encode_msg(~s, ~s~s) -> ~s.~n",
        [MsgType, MsgNamesType, OrList, ret_type_all_msgs(Defs)]),
     gpb_codegen:format_fn(
       encode_msg,
       fun(Msg, MsgName) when is_atom(MsgName) ->
               encode_msg(Msg, MsgName, []);
          ('Msg', Opts) when tuple_size('Msg') >= 1, is_list(Opts) ->
               encode_msg('Msg', element(1,'Msg'), Opts)
       end,
       [repeat_clauses('Msg', [[replace_tree('Msg', ?expr(Msg))]
                               || Mapping == records])]),
     gpb_lib:no_underspecs_dialyzer_attr(encode_msg, 3, Opts),
     ?f("-spec encode_msg(~s, ~s, list()) -> ~s.~n",
        [MsgType, MsgNamesType, ret_type_all_msgs(Defs)]),
     gpb_codegen:format_fn(
       encode_msg,
       fun(Msg, MsgName, Opts) ->
               '<possibly-verify-msg>',
               TrUserData = proplists:get_value(user_data, Opts),
               case MsgName of
                   '<msg-name-match>' ->
                       'encode'('Tr'(Msg, TrUserData), 'TrUserData')
               end
       end,
       [splice_trees('<possibly-verify-msg>',
                     case Verify of
                         optionally ->
                             [?expr(case proplists:get_bool(verify, Opts) of
                                        true  -> verify_msg(Msg, MsgName, Opts);
                                        false -> ok
                                    end)];
                         always ->
                             [?expr(verify_msg(Msg, MsgName, Opts))];
                         never ->
                             []
                     end),
        repeat_clauses(
          '<msg-name-match>',
          [begin
               ElemPath = [MsgName],
               Transl = gpb_gen_translators:find_translation(
                          ElemPath, encode, AnRes),
               [replace_term('<msg-name-match>', MsgName),
                replace_term('encode', gpb_lib:mk_fn(encode_msg_, MsgName)),
                replace_term('Tr', Transl)]
           end
           || {{msg,MsgName}, _Fields} <- Defs]),
        splice_trees('TrUserData', if DoNif -> [];
                                      true  -> [?expr(TrUserData)]
                                   end)]),
     [[?f("%% epb compatibility\n"),
       gpb_lib:no_underspecs_dialyzer_attr(encode, 1, Opts),
       ?f("-spec encode(_) -> ~s.~n", [ret_type_all_msgs(Defs)]),
       gpb_codegen:format_fn(
         encode,
         fun(Msg) -> encode_msg(Msg) end),
       [[begin
             FnName = gpb_lib:mk_fn(encode_, MsgName),
             gpb_lib:no_underspecs_dialyzer_attr(FnName, 1, Opts),
             ?f("-spec ~p(_) -> ~s.~n", [FnName, ret_type_msg(MsgDef)]),
             gpb_codegen:format_fn(
               gpb_lib:mk_fn(encode_, MsgName),
               fun(Msg) -> encode_msg(Msg) end)
         end]
        || {{msg,MsgName}, _Fields}=MsgDef <- Defs]]
      || gpb_lib:get_epb_functions_by_opts(Opts)]].

format_aux_encoders(Defs, AnRes, Opts) ->
    [format_enum_encoders(Defs, AnRes),
     format_type_encoders(AnRes, Opts)
    ].

format_aux_common_encoders(_Defs, AnRes, _Opts) ->
    %% Used also from json encoding
    format_is_empty_string(AnRes).

format_enum_encoders(Defs, #anres{used_types=UsedTypes}) ->
    [gpb_codegen:format_fn(
       gpb_lib:mk_fn(e_enum_, EnumName),
       fun('<EnumSym>', Bin, _TrUserData) -> <<Bin/binary, '<varint-bytes>'>>;
          (V, Bin, _TrUserData) -> % integer (for yet unknown enums)
               e_varint(V, Bin)
       end,
       [repeat_clauses('<EnumSym>',
                       [begin
                            ViBytes = enum_to_binary_fields(EnumValue),
                            [replace_term('<EnumSym>', EnumSym),
                             splice_trees('<varint-bytes>', ViBytes)]
                        end
                        || {EnumSym, EnumValue, _} <- EnumDef])])
     || {{enum, EnumName}, EnumDef} <- Defs,
        gpb_lib:smember({enum,EnumName}, UsedTypes)].

format_map_encoders(Defs, AnRes, Opts0, IncludeStarter) ->
    Opts1 = case gpb_lib:get_2tuples_or_maps_for_maptype_fields_by_opts(Opts0)
            of
                '2tuples' -> [{msgs_as_maps, false} | Opts0];
                maps      -> [{msgs_as_maps, true} | Opts0]
            end,
    format_msg_encoders(Defs, AnRes, Opts1, IncludeStarter).

format_msg_encoders(Defs, AnRes, Opts, IncludeStarter) ->
    [[format_msg_encoder(MsgName, MsgDef, Defs,
                         AnRes, Opts,
                         if Type =:= group -> false;
                            true -> IncludeStarter
                         end)
      || {Type, MsgName, MsgDef} <- gpb_lib:msgs_or_groups(Defs)],
     format_special_field_encoders(Defs, AnRes)].

format_msg_encoder(MsgName, [], _Defs, _AnRes, Opts, IncludeStarter) ->
    case IncludeStarter of
        true ->
            [[[gpb_codegen:format_fn(
                 gpb_lib:mk_fn(encode_msg_, MsgName),
                 fun(_Msg) ->
                         <<>>
                 end),
               "\n"]
              || gpb_lib:get_bypass_wrappers_by_opts(Opts)],
             gpb_codegen:format_fn(
               gpb_lib:mk_fn(encode_msg_, MsgName),
               fun(_Msg, _TrUserData) ->
                       <<>>
               end)];
        false ->
            gpb_codegen:format_fn(
              gpb_lib:mk_fn(encode_msg_, MsgName),
              fun(_Msg, Bin, _TrUserData) ->
                      Bin
              end)
    end;
format_msg_encoder(MsgName, MsgDef, Defs, AnRes, Opts, IncludeStarter) ->
    FNames = gpb_lib:get_field_names(MsgDef),
    FVars = [gpb_lib:var_f_n(I) || I <- lists:seq(1, length(FNames))],
    BVars = [gpb_lib:var_b_n(I) || I <- lists:seq(1, length(FNames)-1)] ++
        [last],
    MsgVar = ?expr(M),
    TrUserDataVar = ?expr(TrUserData),
    {EncodeExprs, _} =
        lists:mapfoldl(
          fun({NewBVar, Field, FVar}, PrevBVar) when NewBVar /= last ->
                  Tr = gpb_gen_translators:mk_find_tr_fn(MsgName, Field, AnRes),
                  EncExpr = field_encode_expr(MsgName, MsgVar, Field, FVar,
                                              PrevBVar, TrUserDataVar,
                                              Defs, Tr, AnRes, Opts),
                  E = ?expr('<NewB>' = '<encode-expr>',
                            [replace_tree('<NewB>', NewBVar),
                             replace_tree('<encode-expr>', EncExpr)]),
                  {E, NewBVar};
             ({last, Field, FVar}, PrevBVar) ->
                  Tr = gpb_gen_translators:mk_find_tr_fn(MsgName, Field, AnRes),
                  EncExpr = field_encode_expr(MsgName, MsgVar, Field, FVar,
                                              PrevBVar, TrUserDataVar,
                                              Defs, Tr, AnRes, Opts),
                  {EncExpr, dummy}
          end,
          ?expr(Bin),
          lists:zip3(BVars, MsgDef, FVars)),
    FnName = gpb_lib:mk_fn(encode_msg_, MsgName),
    FieldMatching =
        case gpb_lib:get_mapping_and_unset_by_opts(Opts) of
            records ->
                gpb_lib:mapping_match(MsgName, lists:zip(FNames, FVars), Opts);
            #maps{unset_optional=present_undefined} ->
                gpb_lib:mapping_match(MsgName, lists:zip(FNames, FVars), Opts);
            #maps{unset_optional=omitted} ->
                FMap = gpb_lib:zip_for_non_opt_fields(MsgDef, FVars),
                if length(FMap) == length(FNames) ->
                        gpb_lib:map_match(FMap, Opts);
                   length(FMap) < length(FNames) ->
                        ?expr('mapmatch' = 'M',
                              [replace_tree('mapmatch',
                                            gpb_lib:map_match(FMap, Opts)),
                               replace_tree('M', MsgVar)])
                end
        end,
    AllowPreencodedSubmsgs = proplists:get_bool(allow_preencoded_submsgs, Opts),
    [[[[[gpb_codegen:format_fn(
           gpb_lib:mk_fn(encode_msg_, MsgName),
           fun(Msg) ->
                   %% The undefined is the default TrUserData
                   'encode_msg_MsgName'(Msg, undefined)
           end,
           [replace_term('encode_msg_MsgName',
                         gpb_lib:mk_fn(encode_msg_, MsgName))]),
         "\n"]
        || gpb_lib:get_bypass_wrappers_by_opts(Opts)],
       gpb_codegen:format_fn(
         FnName,
         fun(Msg, TrUserData) ->
                 call_self(Msg, <<>>, TrUserData)
         end),
       "\n"] || IncludeStarter],
     gpb_codegen:format_fn(
       FnName,
       fun('Preencoded', _Bin, _TrUserData) when is_binary('Preencoded') ->
               'Preencoded';
          ('<msg-matching>', Bin, TrUserData) ->
               '<encode-param-exprs>'
       end,
       [repeat_clauses(
          'Preencoded',
          if AllowPreencodedSubmsgs ->
                  [[replace_tree('Preencoded', gpb_lib:var("Preencoded", []))]];
             not AllowPreencodedSubmsgs ->
                  [] % don't include this clause at all
          end),
        replace_tree('<msg-matching>', FieldMatching),
        splice_trees('<encode-param-exprs>', EncodeExprs)])].

field_encode_expr(MsgName, MsgVar, #?gpb_field{name=FName}=Field,
                  FVar, PrevBVar, TrUserDataVar, Defs, Tr, _AnRes, Opts)->
    FEncoder = mk_field_encode_fn_name(MsgName, Field),
    #?gpb_field{occurrence=Occurrence, type=Type, fnum=FNum, name=FName}=Field,
    TrFVar = gpb_lib:prefix_var("Tr", FVar),
    Transforms1 =
        [replace_term('fieldname', FName),
         replace_tree('<F>', FVar),
         replace_tree('TrF', TrFVar),
         replace_term('Tr', Tr(encode)),
         replace_tree('TrUserData', TrUserDataVar),
         replace_term('<enc>', FEncoder),
         replace_tree('<Bin>', PrevBVar)],
    IsFieldForUnknowns = gpb_lib:is_field_for_unknowns(Field),
    Transforms2 =
        case IsFieldForUnknowns of
            false ->
                KeyBinFields = key_to_binary_fields(FNum, Type),
                [splice_trees('<Key>', KeyBinFields)];
            true ->
                []
        end,
    Transforms = Transforms2 ++ Transforms1,
    IsEnum = case Type of
                 {enum,_} -> true;
                 _ -> false
             end,
    case Occurrence of
        optional ->
            EncodeExpr =
                ?expr(begin
                          'TrF' = 'Tr'('<F>', 'TrUserData'),
                          '<enc>'('TrF', <<'<Bin>'/binary, '<Key>'>>,
                                  'TrUserData')
                      end,
                      Transforms),
            case gpb_lib:get_mapping_and_unset_by_opts(Opts) of
                records ->
                    ?expr(
                       if '<F>' == undefined ->
                               '<Bin>';
                          true ->
                               '<encodeit>'
                       end,
                       [replace_tree('<encodeit>', EncodeExpr) | Transforms]);
                #maps{unset_optional=present_undefined} ->
                    ?expr(
                       if '<F>' == undefined ->
                               '<Bin>';
                          true ->
                               '<encodeit>'
                       end,
                       [replace_tree('<encodeit>', EncodeExpr) | Transforms]);
                #maps{unset_optional=omitted} ->
                    ?expr(
                       case 'M' of
                           '#{fieldname := <F>}' ->
                               '<encodeit>';
                           _ ->
                               '<Bin>'
                       end,
                       [replace_tree('M', MsgVar),
                        replace_tree('#{fieldname := <F>}',
                                     gpb_lib:map_match([{FName,FVar}], Opts)),
                        replace_tree('<encodeit>', EncodeExpr)
                       | Transforms])
            end;
        defaulty ->
            EncodeExpr =
                if Type == string ->
                        ?expr(begin
                                  'TrF' = 'Tr'('<F>', 'TrUserData'),
                                  case is_empty_string('TrF') of
                                      true ->
                                          '<Bin>';
                                      false ->
                                          '<enc>'('TrF',
                                                  <<'<Bin>'/binary, '<Key>'>>,
                                                  'TrUserData')
                                  end
                              end,
                              Transforms);
                   Type == bytes ->
                        ?expr(begin
                                  'TrF' = 'Tr'('<F>', 'TrUserData'),
                                  case iolist_size('TrF') of
                                      0 ->
                                          '<Bin>';
                                      _ ->
                                          '<enc>'('TrF',
                                                  <<'<Bin>'/binary, '<Key>'>>,
                                                  'TrUserData')
                                  end
                              end,
                              Transforms);
                   Type == float;
                   Type == double ->
                        %% Need to compare with +0.0 since Erl 26.1 to avoid
                        %% compilation warnings. Only +0.0 is the type default.
                        ?expr(
                           begin
                               'TrF' = 'Tr'('<F>', 'TrUserData'),
                               if 'TrF' =:= '+0.0';
                                  'TrF' =:= 0 ->
                                       '<Bin>';
                                  true ->
                                       '<enc>'('TrF',
                                               <<'<Bin>'/binary, '<Key>'>>,
                                               'TrUserData')
                               end
                           end,
                           [replace_tree('+0.0', erl_syntax:text("+0.0"))
                            | Transforms]);

                   IsEnum ->
                        TypeDefault = gpb:proto3_type_default(Type, Defs),
                        ?expr(
                           begin
                               'TrF' = 'Tr'('<F>', 'TrUserData'),
                               if 'TrF' =:= '<TypeDefault>';
                                  'TrF' =:= 0 ->
                                       '<Bin>';
                                  true ->
                                       '<enc>'('TrF',
                                               <<'<Bin>'/binary, '<Key>'>>,
                                               'TrUserData')
                               end
                           end,
                           [replace_term('<TypeDefault>', TypeDefault)
                            | Transforms]);
                   true ->
                        TypeDefault = gpb:proto3_type_default(Type, Defs),
                        ?expr(
                           begin
                               'TrF' = 'Tr'('<F>', 'TrUserData'),
                               if 'TrF' =:= '<TypeDefault>' ->
                                       '<Bin>';
                                  true ->
                                       '<enc>'('TrF',
                                               <<'<Bin>'/binary, '<Key>'>>,
                                               'TrUserData')
                               end
                           end,
                           [replace_term('<TypeDefault>', TypeDefault)
                            | Transforms])
                end,
            case gpb_lib:get_mapping_and_unset_by_opts(Opts) of
                records ->
                    ?expr('<encodeit>', [replace_tree('<encodeit>', EncodeExpr) | Transforms]);
                    %% ?expr(
                    %%    if '<F>' == undefined ->
                    %%            '<Bin>';
                    %%       true ->
                    %%            '<encodeit>'
                    %%    end,
                    %%    [replace_tree('<encodeit>', EncodeExpr) | Transforms]);
                #maps{unset_optional=present_undefined} ->
                    ?expr(
                       if '<F>' == undefined ->
                               '<Bin>';
                          true ->
                               '<encodeit>'
                       end,
                       [replace_tree('<encodeit>', EncodeExpr) | Transforms]);
                #maps{unset_optional=omitted} ->
                    ?expr(
                       case 'M' of
                           '#{fieldname := <F>}' ->
                               '<encodeit>';
                           _ ->
                               '<Bin>'
                       end,
                       [replace_tree('M', MsgVar),
                        replace_tree('#{fieldname := <F>}',
                                     gpb_lib:map_match([{FName,FVar}], Opts)),
                        replace_tree('<encodeit>', EncodeExpr)
                        | Transforms])
            end;
        repeated ->
            case gpb_lib:get_mapping_and_unset_by_opts(Opts) of
                records ->
                    ?expr(
                       begin
                           'TrF' = 'Tr'('<F>', 'TrUserData'),
                           if 'TrF' == [] -> '<Bin>';
                              true -> '<enc>'('TrF', '<Bin>', 'TrUserData')
                           end
                       end,
                       Transforms);
                #maps{unset_optional=present_undefined} ->
                    ?expr(
                       begin
                           'TrF' = 'Tr'('<F>', 'TrUserData'),
                           if 'TrF' == [] -> '<Bin>';
                              true -> '<enc>'('TrF', '<Bin>', 'TrUserData')
                           end
                       end,
                       Transforms);
                #maps{unset_optional=omitted} ->
                    ?expr(
                       case 'M' of
                           '#{fieldname := <F>}' ->
                               'TrF' = 'Tr'('<F>', 'TrUserData'),
                               if 'TrF' == [] -> '<Bin>';
                                  true -> '<enc>'('TrF', '<Bin>', 'TrUserData')
                               end;
                           _ ->
                               '<Bin>'
                       end,
                       [replace_tree('M', MsgVar),
                        replace_tree('#{fieldname := <F>}',
                                     gpb_lib:map_match([{FName,FVar}], Opts))
                        | Transforms])
            end;
        required ->
            ?expr(
               begin
                   'TrF' = 'Tr'('<F>', 'TrUserData'),
                   '<enc>'('TrF', <<'<Bin>'/binary, '<Key>'>>,
                           'TrUserData')
               end,
               Transforms)
    end;
field_encode_expr(MsgName, MsgVar, #gpb_oneof{name=FName, fields=OFields},
                  FVar, PrevBVar, TrUserDataVar, Defs, Tr, AnRes, Opts) ->
    ElemPath = [MsgName, FName],
    Transl = gpb_gen_translators:find_translation(ElemPath, encode, AnRes),
    case gpb_lib:get_mapping_and_unset_by_opts(Opts) of
        records ->
            ?expr(if 'F' =:= undefined -> 'Bin';
                     true -> '<expr>'
                  end,
                  [replace_tree('F', FVar),
                   replace_tree('Bin', PrevBVar),
                   replace_tree('<expr>',
                                field_encode_oneof(
                                  MsgName, MsgVar, FVar, OFields,
                                  Transl, TrUserDataVar, PrevBVar,
                                  Defs, Tr, AnRes, Opts))]);
        #maps{unset_optional=present_undefined} ->
            ?expr(if 'F' =:= undefined -> 'Bin';
                     true -> '<expr>'
                  end,
                  [replace_tree('F', FVar),
                   replace_tree('Bin', PrevBVar),
                   replace_tree('<expr>',
                                field_encode_oneof(
                                  MsgName, MsgVar, FVar, OFields,
                                  Transl, TrUserDataVar, PrevBVar,
                                  Defs, Tr, AnRes, Opts))]);
        #maps{unset_optional=omitted, oneof=tuples} ->
            ?expr(case 'M' of
                      '#{fname:=F}' -> '<expr>';
                      _ -> 'Bin'
                  end,
                  [replace_tree('#{fname:=F}',
                                gpb_lib:map_match([{FName, FVar}], Opts)),
                   replace_tree('M', MsgVar),
                   replace_tree('Bin', PrevBVar),
                   replace_tree('<expr>',
                                field_encode_oneof(
                                  MsgName, MsgVar, FVar, OFields,
                                  Transl, TrUserDataVar, PrevBVar,
                                  Defs, Tr, AnRes, Opts))]);
        #maps{unset_optional=omitted, oneof=flat} ->
            ?expr(case 'M' of
                      '#{tag:=Val}' -> '<expr>';
                      _ -> 'Bin'
                  end,
                  [replace_tree('M', MsgVar),
                   replace_tree('Bin', PrevBVar),
                   repeat_clauses(
                     '#{tag:=Val}',
                     field_encode_oneof_flat(
                       '#{tag:=Val}', MsgName, MsgVar, FVar, OFields,
                       Transl, TrUserDataVar, PrevBVar,
                       Defs, Tr, AnRes, Opts))])
    end.

field_encode_oneof(MsgName, MsgVar, FVar, OFields,
                   Transl, TrUserDataVar, PrevBVar, Defs, Tr, AnRes, Opts) ->
    TVar = gpb_lib:prefix_var("T", FVar),
    ?expr(case 'Tr'('F', 'TrUserData') of
              '{tag,TVar}' -> '<expr>'
          end,
          [replace_term('Tr', Transl),
           replace_tree('TrUserData', TrUserDataVar),
           replace_tree('F', FVar),
           repeat_clauses(
             '{tag,TVar}',
             [begin
                  TagTuple = ?expr({tag,'TVar'}, [replace_term(tag,Name),
                                                  replace_tree('TVar', TVar)]),
                  %% undefined is already handled, we have a match,
                  %% the field occurs, as if it had been required
                  OField2 = OField#?gpb_field{occurrence=required},
                  Tr2 = Tr({update_elem_path,Name}),
                  EncExpr = field_encode_expr(MsgName, MsgVar, OField2, TVar,
                                              PrevBVar, TrUserDataVar,
                                              Defs, Tr2, AnRes, Opts),
                  [replace_tree('{tag,TVar}', TagTuple),
                   replace_tree('<expr>', EncExpr)]
              end
              || #?gpb_field{name=Name}=OField <- OFields])]).

field_encode_oneof_flat(ClauseMarker, MsgName, MsgVar, FVar, OFields,
                        Transl, TrUserDataVar, PrevBVar, Defs, Tr, AnRes, Opts) ->
    OFVar = gpb_lib:prefix_var("O", FVar),
    [begin
         MatchPattern = gpb_lib:map_match([{Name, OFVar}], Opts),
         %% undefined is already handled, we have a match,
         %% the field occurs, as if it had been required
         OField2 = OField#?gpb_field{occurrence=required},
         Tr2 = Tr({update_elem_path,Name}),
         EncExpr = field_encode_expr(MsgName, MsgVar, OField2, OFVar,
                                     PrevBVar, TrUserDataVar,
                                     Defs, Tr2, AnRes, Opts),
         TrEncExpr = ?expr('Tr'('EncExpr', 'TrUserData'),
                           [replace_term('Tr', Transl),
                            replace_tree('EncExpr', EncExpr),
                            replace_tree('TrUserData', TrUserDataVar)]),
             [replace_tree(ClauseMarker, MatchPattern),
              replace_tree('<expr>', TrEncExpr)]
         end
         || #?gpb_field{name=Name}=OField <- OFields].


mk_field_encode_fn_name(MsgName, #?gpb_field{occurrence=repeated, name=FName})->
    gpb_lib:mk_fn(e_field_, MsgName, FName);
mk_field_encode_fn_name(MsgName, #?gpb_field{type={msg,_Msg}, name=FName}) ->
    gpb_lib:mk_fn(e_mfield_, MsgName, FName);
mk_field_encode_fn_name(MsgName, #?gpb_field{type={group,_Nm}, name=FName}) ->
    gpb_lib:mk_fn(e_mfield_, MsgName, FName);
mk_field_encode_fn_name(_MsgName, #?gpb_field{type={enum,EnumName}}) ->
    gpb_lib:mk_fn(e_enum_, EnumName);
mk_field_encode_fn_name(_MsgName, #?gpb_field{type=sint32}) ->
    gpb_lib:mk_fn(e_type_, sint);
mk_field_encode_fn_name(_MsgName, #?gpb_field{type=sint64}) ->
    gpb_lib:mk_fn(e_type_, sint);
mk_field_encode_fn_name(_MsgName, #?gpb_field{type=uint32}) ->
    e_varint;
mk_field_encode_fn_name(_MsgName, #?gpb_field{type=uint64}) ->
    e_varint;
mk_field_encode_fn_name(MsgName,  #?gpb_field{type=Type}=F) ->
    case Type of
        {map,KeyType,ValueType} ->
            MapAsMsgMame = gpb_lib:map_type_to_msg_name(KeyType, ValueType),
            F2 = F#?gpb_field{type = {msg,MapAsMsgMame}},
            mk_field_encode_fn_name(MsgName, F2);
        _ ->
            gpb_lib:mk_fn(e_type_, Type)
    end.

format_special_field_encoders(Defs, AnRes) ->
    lists:reverse( %% so generated auxiliary functions come in logical order
      gpb_lib:fold_msg_or_group_fields(
        fun(_Type, MsgName, #?gpb_field{occurrence=repeated}=FieldDef, Acc) ->
                [format_field_encoder(MsgName, FieldDef, AnRes) | Acc];
           (_Type, MsgName, #?gpb_field{type={msg,_}}=FieldDef, Acc)->
                [format_field_encoder(MsgName, FieldDef, AnRes) | Acc];
           (_Type, MsgName, #?gpb_field{type={group,_}}=FieldDef, Acc)->
                [format_field_encoder(MsgName, FieldDef, AnRes) | Acc];
           (_Type, _MsgName, #?gpb_field{}, Acc) ->
                Acc
        end,
        [],
        Defs)).

format_field_encoder(MsgName, FieldDef, AnRes) ->
    #?gpb_field{occurrence=Occurrence} = FieldDef,
    RFieldDef = FieldDef#?gpb_field{occurrence=required},
    Occurrence2 =
        case Occurrence of
            repeated ->
                case gpb_lib:is_field_for_unknowns(FieldDef) of
                    true  -> {repeated, unknown};
                    false -> {repeated, {packed, gpb_lib:is_packed(FieldDef)}}
                end;
            optional -> optional;
            defaulty -> defaulty;
            required -> required
        end,
    [possibly_format_mfield_encoder(MsgName, RFieldDef, AnRes),
     case Occurrence2 of
         {repeated, {packed, false}} ->
             format_repeated_field_encoder2(MsgName, FieldDef, AnRes);
         {repeated, {packed, true}} ->
             format_packed_field_encoder2(MsgName, FieldDef, AnRes);
         {repeated, unknown} ->
             format_unknown_field_encoder2(MsgName, FieldDef, AnRes);
         optional ->
             [];
         defaulty ->
             [];
         required ->
             []
     end].

possibly_format_mfield_encoder(MsgName,
                               #?gpb_field{type={msg,SubMsg}}=FieldDef,
                               AnRes) ->
    FnName = mk_field_encode_fn_name(MsgName, FieldDef),
    case is_msgsize_known_at_generationtime(SubMsg, AnRes) of
        no ->
            gpb_codegen:format_fn(
              FnName,
              fun(Msg, Bin, TrUserData) ->
                      SubBin = '<encode-msg>'(Msg, <<>>, TrUserData),
                      Bin2 = e_varint(byte_size(SubBin), Bin),
                      <<Bin2/binary, SubBin/binary>>
              end,
              [replace_term('<encode-msg>',
                            gpb_lib:mk_fn(encode_msg_, SubMsg))]);
        {yes, MsgSize} when MsgSize > 0 ->
            MsgSizeBytes = gpb_lib:varint_to_binary_fields(MsgSize),
            gpb_codegen:format_fn(
              FnName,
              fun(Msg, Bin, TrUserData) ->
                      Bin2 = <<Bin/binary, '<msg-size>'>>,
                      '<encode-msg>'(Msg, Bin2, TrUserData)
              end,
              [splice_trees('<msg-size>', MsgSizeBytes),
               replace_term('<encode-msg>',
                            gpb_lib:mk_fn(encode_msg_, SubMsg))]);
        {yes, 0} ->
            %% special case, there will not be any encode_msg_<MsgName>/2
            %% function generated, so don't call it.
            gpb_codegen:format_fn(
              FnName,
              fun(_Msg, Bin, _TrUserData) -> <<Bin/binary, 0>> end)
    end;
possibly_format_mfield_encoder(MsgName,
                               #?gpb_field{type={map,KType,VType}}=FieldDef,
                               AnRes) ->
    MapAsMsgName = gpb_lib:map_type_to_msg_name(KType, VType),
    FieldDef2 = FieldDef#?gpb_field{type = {msg,MapAsMsgName}},
    possibly_format_mfield_encoder(MsgName, FieldDef2, AnRes);
possibly_format_mfield_encoder(MsgName,
                               #?gpb_field{type={group,GroupName},
                                           fnum=FNum}=FieldDef,
                               _AnRes) ->
    FnName = mk_field_encode_fn_name(MsgName, FieldDef),
    EndTagBytes = key_to_binary_fields(FNum, group_end),
    gpb_codegen:format_fn(
      FnName,
      fun(Msg, Bin, TrUserData) ->
              GroupBin = '<encode-msg>'(Msg, <<>>, TrUserData),
              <<Bin/binary, GroupBin/binary, 'EndTagBytes'>>
      end,
      [replace_term('<encode-msg>', gpb_lib:mk_fn(encode_msg_, GroupName)),
       splice_trees('EndTagBytes', EndTagBytes)]);
possibly_format_mfield_encoder(_MsgName, _FieldDef, _Defs) ->
    [].

is_msgsize_known_at_generationtime(MsgName, #anres{known_msg_size=MsgSizes}) ->
    case dict:fetch(MsgName, MsgSizes) of
        MsgSize when is_integer(MsgSize) ->
            {yes, MsgSize};
        undefined ->
            no
    end.

format_repeated_field_encoder2(MsgName, FDef, AnRes) ->
    #?gpb_field{fnum=FNum, type=Type, name=FName} = FDef,
    FnName = mk_field_encode_fn_name(MsgName, FDef),
    ElemEncoderFn = mk_field_encode_fn_name(
                      MsgName, FDef#?gpb_field{occurrence=required}),
    KeyBytes = key_to_binary_fields(FNum, Type),
    ElemPath = [MsgName,FName,[]],
    Transl = gpb_gen_translators:find_translation(ElemPath, encode, AnRes),
    gpb_codegen:format_fn(
      FnName,
      fun([Elem | Rest], Bin, TrUserData) ->
              Bin2 = <<Bin/binary, '<KeyBytes>'>>,
              Bin3 = '<encode-elem>'('Tr'(Elem, TrUserData), Bin2, TrUserData),
              call_self(Rest, Bin3, TrUserData);
         ([], Bin, _TrUserData) ->
              Bin
      end,
      [splice_trees('<KeyBytes>', KeyBytes),
       replace_term('<encode-elem>', ElemEncoderFn),
       replace_term('Tr', Transl)]).

format_unknown_field_encoder2(MsgName, #?gpb_field{}=FDef, _AnRes) ->
    FnName = mk_field_encode_fn_name(MsgName, FDef),
    gpb_codegen:format_fn(
      FnName,
      fun(Elems, Bin, _TrUserData) ->
              e_unknown_elems(Elems, Bin)
      end).

format_unknown_encoder() ->
    FnName = e_unknown_elems,
    [gpb_lib:nowarn_unused_function(FnName, 2),
     gpb_codegen:format_fn(
       FnName,
       fun([Elem | Rest], Bin) ->
               BinR =
                   case Elem of
                       {varint, FNum, N} ->
                           BinF = e_varint(FNum bsl 3, Bin),
                           e_varint(N, BinF);
                       {length_delimited, FNum, Data} ->
                           BinF = e_varint((FNum bsl 3) bor 2, Bin),
                           BinL = e_varint(byte_size(Data), BinF),
                           <<BinL/binary, Data/binary>>;
                       {group, FNum, GroupFields} ->
                           Bin1 = e_varint((FNum bsl 3) bor 3, Bin), % gr start
                           Bin2 = call_self(GroupFields, Bin1),
                           e_varint((FNum bsl 3) bor 4, Bin2); % gr end
                       {fixed32, FNum, V} ->
                           BinF = e_varint((FNum bsl 3) bor 5, Bin),
                           <<BinF/binary, V:32/little>>;
                       {fixed64, FNum, V} ->
                           BinF = e_varint((FNum bsl 3) bor 1, Bin),
                           <<BinF/binary, V:64/little>>
                   end,
               call_self(Rest, BinR);
          ([], Bin) ->
               Bin
       end)].

format_packed_field_encoder2(MsgName, #?gpb_field{type=Type}=FDef, AnRes) ->
    case packed_byte_size_can_be_computed(Type) of
        {yes, BitLen, BitType} ->
            format_knownsize_packed_field_encoder2(MsgName, FDef,
                                                   BitLen, BitType, AnRes);
        no ->
            format_unknownsize_packed_field_encoder2(MsgName, FDef, AnRes)
    end.

packed_byte_size_can_be_computed(fixed32)  -> {yes, 32, [little]};
packed_byte_size_can_be_computed(sfixed32) -> {yes, 32, [little,signed]};
packed_byte_size_can_be_computed(float)    -> {yes, 32, float};
packed_byte_size_can_be_computed(fixed64)  -> {yes, 64, [little]};
packed_byte_size_can_be_computed(sfixed64) -> {yes, 64, [little,signed]};
packed_byte_size_can_be_computed(double)   -> {yes, 64, double};
packed_byte_size_can_be_computed(_)        -> no.

format_knownsize_packed_field_encoder2(MsgName, #?gpb_field{name=FName,
                                                            fnum=FNum}=FDef,
                                       BitLen, BitType, AnRes) ->
    FnName = mk_field_encode_fn_name(MsgName, FDef),
    KeyBytes = key_to_binary_fields(FNum, bytes),
    PackedFnName = gpb_lib:mk_fn(e_pfield_, MsgName, FName),
    ElemPath = [MsgName, FName, []],
    TranslFn = gpb_gen_translators:find_translation(ElemPath, encode, AnRes),
    [gpb_codegen:format_fn(
       FnName,
       fun(Elems, Bin, TrUserData) when Elems =/= [] ->
               Bin2 = <<Bin/binary, '<KeyBytes>'>>,
               Bin3 = e_varint(length(Elems) * '<ElemLen>', Bin2),
               '<encode-packed>'(Elems, Bin3, TrUserData);
          ([], Bin, _TrUserData) ->
               Bin
       end,
       [splice_trees('<KeyBytes>', KeyBytes),
        replace_term('<ElemLen>', BitLen div 8),
        replace_term('<encode-packed>', PackedFnName)]),
     case BitType of
         float ->
             format_packed_float_encoder(PackedFnName, TranslFn);
         double ->
             format_packed_double_encoder(PackedFnName, TranslFn);
         _ ->
             gpb_codegen:format_fn(
               PackedFnName,
               fun([Value | Rest], Bin, TrUserData) ->
                       TrValue = 'Tr'(Value, TrUserData),
                       Bin2 = <<Bin/binary, TrValue:'<Size>'/'<BitType>'>>,
                       call_self(Rest, Bin2, TrUserData);
                  ([], Bin, _TrUserData) ->
                       Bin
               end,
               [replace_term('<Size>', BitLen),
                splice_trees('<BitType>',
                             [erl_syntax:atom(T) || T <- BitType]),
                replace_term('Tr', TranslFn)])
     end].


format_unknownsize_packed_field_encoder2(MsgName,
                                         #?gpb_field{name=FName,
                                                     fnum=FNum}=FDef,
                                         AnRes) ->
    FnName = mk_field_encode_fn_name(MsgName, FDef),
    ElemEncoderFn = mk_field_encode_fn_name(
                      MsgName,
                      FDef#?gpb_field{occurrence=required}),
    KeyBytes = key_to_binary_fields(FNum, bytes),
    PackedFnName = gpb_lib:mk_fn(e_pfield_, MsgName, FName),
    ElemPath = [MsgName,FName,[]],
    Transl = gpb_gen_translators:find_translation(ElemPath, encode, AnRes),
    [gpb_codegen:format_fn(
       FnName,
       fun(Elems, Bin, TrUserData) when Elems =/= [] ->
               SubBin = '<encode-packed>'(Elems, <<>>, TrUserData),
               Bin2 = <<Bin/binary, '<KeyBytes>'>>,
               Bin3 = e_varint(byte_size(SubBin), Bin2),
               <<Bin3/binary, SubBin/binary>>;
          ([], Bin, _TrUserData) ->
               Bin
       end,
       [splice_trees('<KeyBytes>', KeyBytes),
        replace_term('<encode-packed>', PackedFnName)]),
     gpb_codegen:format_fn(
       PackedFnName,
       fun([Value | Rest], Bin, TrUserData) ->
               Bin2 = '<encode-elem>'('Tr'(Value, TrUserData), Bin, TrUserData),
               call_self(Rest, Bin2, TrUserData);
          ([], Bin, _TrUserData) ->
               Bin
       end,
       [replace_term('<encode-elem>', ElemEncoderFn),
        replace_term('Tr', Transl)])].

format_type_encoders(AnRes, Opts) ->
    [format_varlength_field_encoders(AnRes, Opts),
     format_fixlength_field_encoders(AnRes, Opts),
     format_unknown_encoder(),
     format_varint_encoder()].

format_varlength_field_encoders(AnRes, Opts) ->
    [format_sint_encoder(),
     format_int_encoder(int32, 32, AnRes, Opts),
     format_int_encoder(int64, 64, AnRes, Opts),
     format_bool_encoder(AnRes, Opts),
     format_string_encoder(AnRes, Opts),
     format_bytes_encoder(AnRes, Opts)].

format_fixlength_field_encoders(AnRes, Opts) ->
    [format_fixed_encoder(fixed32,  32, [little], AnRes, Opts),
     format_fixed_encoder(sfixed32, 32, [little,signed], AnRes, Opts),
     format_fixed_encoder(fixed64,  64, [little], AnRes, Opts),
     format_fixed_encoder(sfixed64, 64, [little,signed], AnRes, Opts),
     format_float_encoder(float, AnRes, Opts),
     format_double_encoder(double, AnRes, Opts)].

format_sint_encoder() ->
    [gpb_lib:nowarn_unused_function(e_type_sint,3),
     gpb_codegen:format_fn(
       e_type_sint,
       fun(Value, Bin, _TrUserData) when Value >= 0 ->
               e_varint(Value * 2, Bin);
          (Value, Bin, _TrUserData) ->
               e_varint(Value * -2 - 1, Bin)
       end)].

format_int_encoder(Type, _BitLen, AnRes, Opts) ->
    FnName = gpb_lib:mk_fn(e_type_, Type),
    [gpb_lib:nowarn_unused_function(FnName, 3),
     maybe_no_dialyzer_warn_funcion(Type, FnName, 3, AnRes, Opts),
     gpb_codegen:format_fn(
       FnName,
       fun(Value, Bin, _TrUserData) when 0 =< Value, Value =< 127 ->
               <<Bin/binary, Value>>; %% fast path
          (Value, Bin, _TrUserData) ->
               %% Encode as a 64 bit value, for interop compatibility.
               %% Some implementations don't decode 32 bits properly,
               %% and Google's protobuf (C++) encodes as 64 bits
               <<N:64/unsigned-native>> = <<Value:64/signed-native>>,
               e_varint(N, Bin)
       end)].

format_bool_encoder(AnRes, Opts) ->
    FnName = e_type_bool,
    [gpb_lib:nowarn_unused_function(FnName, 3),
     maybe_no_dialyzer_warn_funcion(bool, FnName, 3, AnRes, Opts),
     gpb_codegen:format_fn(
       FnName,
       fun(true, Bin, _TrUserData)  -> <<Bin/binary, 1>>;
          (false, Bin, _TrUserData) -> <<Bin/binary, 0>>;
          (1, Bin, _TrUserData) -> <<Bin/binary, 1>>;
          (0, Bin, _TrUserData) -> <<Bin/binary, 0>>
       end)].

format_fixed_encoder(Type, BitLen, BitType, AnRes, Opts) ->
    FnName = gpb_lib:mk_fn(e_type_, Type),
    [gpb_lib:nowarn_unused_function(FnName, 3),
     maybe_no_dialyzer_warn_funcion(Type, FnName, 3, AnRes, Opts),
     gpb_codegen:format_fn(
       FnName,
       fun(Value, Bin, _TrUserData) ->
               <<Bin/binary, Value:'<Sz>'/'<T>'>>
       end,
       [replace_term('<Sz>', BitLen),
        splice_trees('<T>', [erl_syntax:atom(T) || T <- BitType])])].

format_packed_float_encoder(FnName, TranslFn) ->
    gpb_codegen:format_fn(
      FnName,
      fun([V | Rest], Bin, TrUserData) ->
              TrV = 'Tr'(V, TrUserData),
              Bin2 = if is_number(TrV) ->
                             <<Bin/binary, TrV:32/little-float>>;
                        TrV =:= infinity ->
                             <<Bin/binary, 0:16,128,127>>;
                        TrV =:= '-infinity' ->
                             <<Bin/binary, 0:16,128,255>>;
                        TrV =:= nan ->
                             <<Bin/binary, 0:16,192,127>>
                     end,
              call_self(Rest, Bin2, TrUserData);
         ([], Bin, _TrUserData) ->
              Bin
      end,
      [replace_term('Tr', TranslFn)]).

format_packed_double_encoder(FnName, TranslFn) ->
    gpb_codegen:format_fn(
      FnName,
      fun([V | Rest], Bin, TrUserData) ->
              TrV = 'Tr'(V, TrUserData),
              Bin2 = if is_number(TrV) ->
                             <<Bin/binary, TrV:64/float-little>>;
                        TrV =:= infinity ->
                             <<Bin/binary, 0:48,240,127>>;
                        TrV =:= '-infinity' ->
                             <<Bin/binary, 0:48,240,255>>;
                        TrV =:= nan ->
                             <<Bin/binary, 0:48,248,127>>
                     end,
              call_self(Rest, Bin2, TrUserData);
         ([], Bin, _TrUserData) ->
              Bin
      end,
      [replace_term('Tr', TranslFn)]).

format_float_encoder(Type, AnRes, Opts) ->
    FnName = gpb_lib:mk_fn(e_type_, Type),
    [gpb_lib:nowarn_unused_function(FnName, 3),
     maybe_no_dialyzer_warn_funcion(Type, FnName, 3, AnRes, Opts),
     gpb_codegen:format_fn(
       FnName,
       fun(V, Bin, _) when is_number(V) -> <<Bin/binary, V:32/little-float>>;
          (infinity, Bin, _)            -> <<Bin/binary, 0:16,128,127>>;
          ('-infinity', Bin, _)         -> <<Bin/binary, 0:16,128,255>>;
          (nan, Bin, _)                 -> <<Bin/binary, 0:16,192,127>>
       end)].

format_double_encoder(Type, AnRes, Opts) ->
    FnName = gpb_lib:mk_fn(e_type_, Type),
    [gpb_lib:nowarn_unused_function(FnName, 3),
     maybe_no_dialyzer_warn_funcion(Type, FnName, 3, AnRes, Opts),
     gpb_codegen:format_fn(
       FnName,
       fun(V, Bin, _) when is_number(V) -> <<Bin/binary, V:64/little-float>>;
          (infinity, Bin, _)            -> <<Bin/binary, 0:48,240,127>>;
          ('-infinity', Bin, _)         -> <<Bin/binary, 0:48,240,255>>;
          (nan, Bin, _)                 -> <<Bin/binary, 0:48,248,127>>
       end)].

format_string_encoder(AnRes, Opts) ->
    FnName = e_type_string,
    [gpb_lib:nowarn_unused_function(FnName, 3),
     maybe_no_dialyzer_warn_funcion(string, FnName, 3, AnRes, Opts),
     gpb_codegen:format_fn(
       FnName,
       fun(S, Bin, _TrUserData) ->
               Utf8 = unicode:characters_to_binary(S),
               Bin2 = e_varint(byte_size(Utf8), Bin),
               <<Bin2/binary, Utf8/binary>>
       end)].

format_bytes_encoder(AnRes, Opts) ->
    FnName = e_type_bytes,
    [gpb_lib:nowarn_unused_function(FnName, 3),
     maybe_no_dialyzer_warn_funcion(bytes, FnName, 3, AnRes, Opts),
     gpb_codegen:format_fn(
       FnName,
       fun(Bytes, Bin, _TrUserData) when is_binary(Bytes) ->
               Bin2 = e_varint(byte_size(Bytes), Bin),
               <<Bin2/binary, Bytes/binary>>;
          (Bytes, Bin, _TrUserData) when is_list(Bytes) ->
               BytesBin = iolist_to_binary(Bytes),
               Bin2 = e_varint(byte_size(BytesBin), Bin),
               <<Bin2/binary, BytesBin/binary>>
       end)].

format_varint_encoder() ->
    [gpb_lib:nowarn_unused_function(e_varint, 3),
     gpb_codegen:format_fn(
       e_varint,
       fun(N, Bin, _TrUserData) ->
               e_varint(N, Bin)
       end),
     gpb_lib:nowarn_unused_function(e_varint, 2),
     gpb_codegen:format_fn(
       e_varint,
       fun(N, Bin) when N =< 127 ->
               <<Bin/binary, N>>;
          (N, Bin) ->
               Bin2 = <<Bin/binary, (N band 127 bor 128)>>,
               call_self(N bsr 7, Bin2)
       end)].

enum_to_binary_fields(Value) ->
    %% Encode as a 64 bit value, for interop compatibility.
    %% Some implementations don't decode 32 bits properly,
    %% and Google's protobuf (C++) encodes as 64 bits
    <<N:64/unsigned-native>> = <<Value:64/signed-native>>,
    gpb_lib:varint_to_binary_fields(N).

key_to_binary_fields(FNum, {group,_}) ->
    key_to_binary_fields(FNum, group_start);
key_to_binary_fields(FNum, Type) ->
    Key = (FNum bsl 3) bor gpb:encode_wiretype(Type),
    gpb_lib:varint_to_binary_fields(Key).

format_is_empty_string(#anres{has_p3_opt_strings=false}) ->
    "";
format_is_empty_string(#anres{has_p3_opt_strings=true}) ->
    [gpb_codegen:format_fn(
       is_empty_string,
       fun("") -> true;
          (<<>>) -> true;
          (L) when is_list(L) -> not string_has_chars(L);
          (B) when is_binary(B) -> false
       end),
     gpb_codegen:format_fn(
       string_has_chars,
       fun([C | _]) when is_integer(C) -> true; % common case
          ([H | T]) ->
               case string_has_chars(H) of
                   true  -> true;
                   false -> call_self(T)
               end;
          (B) when is_binary(B), byte_size(B) =/= 0 -> true;
          (C) when is_integer(C) -> true;
          (<<>>) -> false;
          ([]) -> false
       end)].

maybe_no_dialyzer_warn_funcion(Type, FnName, Arity,
                               #anres{types_only_via_translations=TrTypes},
                               Opts) ->
    case sets:is_element(Type, TrTypes) of
        true ->
            gpb_lib:nowarn_dialyzer_attr(FnName, Arity, Opts);
        false ->
            []
    end.

ret_type_all_msgs(Defs) ->
    case at_least_one_msg_is_nonempty(Defs) of
        true  -> "binary()";
        false -> "<<>>"
    end.

at_least_one_msg_is_nonempty([{{msg, _MsgName}, _Fields}=MsgDef | Rest]) ->
    case msg_is_nonempty(MsgDef) of
        true  -> true;
        false -> at_least_one_msg_is_nonempty(Rest)
    end;
at_least_one_msg_is_nonempty([_ | Rest]) ->
    at_least_one_msg_is_nonempty(Rest);
at_least_one_msg_is_nonempty([]) ->
    false.

ret_type_msg(MsgDef) ->
    %% Dialyzer -Wunderspecs will warn if the message is empty,
    %% and we say encode_msg returns binary(), because the spec
    %% is then "more allowing than the success typing."
    case msg_is_nonempty(MsgDef) of
        true  -> "binary()";
        false -> "<<>>"
    end.

msg_is_nonempty({{msg, _MsgName}, Fields}) ->
    Fields =/= [].
