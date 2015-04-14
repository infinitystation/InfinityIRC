-module(common).
-compile(export_all).

-record(user, {nick, username, host}).

debug(What, Msg) -> io:fwrite("[~s] ~s~n", [What, Msg]).
debug(What, Format, List) ->
	io:fwrite("[~s] ~s~n", [What, io_lib:format(Format, List)]).

% Spawn this method to have your code compiled and reloaded.
purge_call(Module, Function, Param) ->
	code:purge(Module),
	compile:file(Module),
	code:load_file(Module),
	Module:Function(Param).

raw_send(Sock, Msg) ->
	%debug("SEND", Msg),
	gen_tcp:send(Sock, [Msg, "\r\n"]).

start() ->
	spawn(core, init, []),
	spawn(bot, init, []),
	ok.
start(Server, Port) ->
	spawn(core, init, [Server, Port]),
	spawn(bot, init, []),
	ok.

tcp_parse(S, M) ->
	Tokens = string:tokens(M, " "),
	case hd(Tokens) of
		"PING" -> tcp_send(S, {pong, string:join(tl(Tokens), " ")});
		":" ++ RawOrigin ->
			Origin = parse_origin(RawOrigin),
			case tl(Tokens) of
				% Setup & system
				["NICK", Nick] -> {irc, {nick, {Origin, Nick}}};
				["QUIT" | Reason] -> {irc, {quit, {Origin, Reason}}};
				["MODE" | Params] -> {irc, {mode, {Origin, Params}}};
				["KICK", Channel, Nick | Params] ->
					{irc, {kick, {Origin, Nick, Channel, [tl(hd(Params)) | tl(Params)]}}};
				["TOPIC", Channel | Topic] ->
					{irc, {topic, {Origin, Channel, [tl(hd(Topic)) | tl(Topic)]}}};

				% Channel management
				["JOIN", Channel] -> {irc, {join, {Origin, Channel}}};
				["PART", Channel | Msg] -> {irc, {part, {Origin, Channel, Msg}}};
				
				% Messaging
				["PRIVMSG", Channel, First | Rest] -> parse_privmsg(Origin, Channel, [tl(First) | Rest]);
				["NOTICE", Channel, First | Rest] -> parse_notice(Origin, Channel, [tl(First) | Rest]);
				
				% Errors
				[Cmd | Params] ->
					case string:to_integer(Cmd) of
						{error, _} -> common:debug("PARSE", "Unknown TCP message received; ~s : ~p", [Cmd, Params]);
						{I, []} ->
							case numeric_parse(I) of
								{unknown, B} -> common:debug("PARSE", "Unknown numeric received; ~p : ~s", [B, string:join(Params, " ")]);
								{A, B} -> common:debug("PARSE", "Numeric received; ~p_~p : ~s", [A, B, string:join(Params, " ")])
							end;
						{_, _} -> common:debug("PARSE", "Unknown TCP message received; ~s : ~s", [Cmd, string:join(Params, " ")])
					end
			end
	end.

parse_ctcp(Origin, Tokens) ->
	case hd(Tokens) of
		"ACTION" -> {action, Origin, tl(Tokens)};
		"VERSION" -> {version, Origin, tl(Tokens)};
		_ -> {unknown, Origin, Tokens}
	end.

parse_privmsg(Origin, Channel, Message) ->
	case hd(Message) of
		[] -> ok;
		_ ->
			FirstFirst = hd(hd(Message)),
			LastLast = lists:last(lists:last(Message)),
			if
				FirstFirst == 1 andalso LastLast == 1 -> 
						StrippedMessage = string:tokens(lists:reverse(tl(lists:reverse(tl(string:join(Message, " "))))), " "),
						{irc, {ctcp, parse_ctcp(Origin, StrippedMessage)}};
				true -> {irc, {msg, {Origin, Channel, Message}}}
			end
	end.

parse_notice(Origin, Channel, Message) ->
	FirstFirst = hd(hd(Message)),
	LastLast = lists:last(lists:last(Message)),
	if
		FirstFirst == 1 andalso LastLast == 1 -> 
				StrippedMessage = string:tokens(lists:reverse(tl(lists:reverse(tl(string:join(Message, " "))))), " "),
				{irc, {ctcp_re, parse_ctcp(Origin, StrippedMessage)}};
		true -> {irc, {notice, {Origin, Channel, Message}}}
	end.

tcp_send(S, {pass, Pass}) ->					raw_send(S, ["PASS ", Pass]);
tcp_send(S, {user, {User, Mode, Real}} ) ->		raw_send(S, ["USER ",User," ",Mode," * :",Real]);
tcp_send(S, {nick, Nick}) ->					raw_send(S, ["NICK ",Nick]);
tcp_send(S, {quit, Message}) ->					raw_send(S, ["QUIT :",Message]), core!quit;
tcp_send(S, {pong, Params}) ->					raw_send(S, ["PONG ",Params]);
tcp_send(S, {join, Channel}) ->					raw_send(S, ["JOIN ",Channel]);
tcp_send(S, {part, {Channel, Reason}}) ->		raw_send(S, ["PART ",Channel," :",Reason]);
tcp_send(S, {msg, {Recipient, Message}}) ->		raw_send(S, ["PRIVMSG ",Recipient," :",Message]);
tcp_send(S, {ctcp, {version, R, V}}) ->			raw_send(S, ["PRIVMSG ",R," :\1VERSION ",V,1]);
tcp_send(S, {ctcp, {action, R, V}}) ->			raw_send(S, ["PRIVMSG ",R," :\1ACTION ",V,1]);
tcp_send(S, {ctcp, {unknown, R, V}}) ->			raw_send(S, ["PRIVMSG ",R," :\1",V,1]);
tcp_send(S, {notice, {Recipient, Message}}) ->	raw_send(S, ["NOTICE ",Recipient," :",Message]);
tcp_send(S, {ctcp_re, {version, R, V}}) ->		raw_send(S, ["NOTICE ",R," :\1VERSION ",V,1]);
tcp_send(S, {ctcp_re, {action, R, V}}) ->              raw_send(S, ["NOTICE ",R," :\1ACTION ",V,1]);
tcp_send(S, {ctcp_re, {unknown, R, V}}) ->              raw_send(S, ["NOTICE ",R," :\1",V,1]);
tcp_send(_S, {T, X}) ->							common:debug("SEND", "Unknown IRC message type or fomat {~p, ~p}", [T, X]).

parse_origin(O) ->
	case re:run(O, "([^!@]+)(!([^!@]+)@([^!@]+))?", [{capture, all_but_first, list}]) of
		nomatch -> notuser;
		{match, [N, _, U, H]}-> #user{nick=N, username=U, host=H};
		{match, [Svr]} -> Svr;
		T -> common:debug("PARSE", "Something broke in user_string; ~p", [T]), error
	end.

numeric_parse(Num) ->
	case Num of
		200 -> {rpl, trace_link};
		201 -> {rpl, trace_connecting};
		202 -> {rpl, trace_handshake};
		203 -> {rpl, trace_unknown};
		204 -> {rpl, trace_operator};
		205 -> {rpl, trace_user};
		206 -> {rpl, trace_server};
		208 -> {rpl, trace_new_type};
		211 -> {rpl, stats_link_info};
		212 -> {rpl, stats_commands};
		213 -> {rpl, stats_cline};
		214 -> {rpl, stats_nline};
		215 -> {rpl, stats_iline};
		216 -> {rpl, stats_kline};
		218 -> {rpl, stats_yline};
		219 -> {rpl, end_of_stats};
		221 -> {rpl, u_mode_is};
		241 -> {rpl, stats_lline};
		242 -> {rpl, stats_uptime};
		243 -> {rpl, stats_oline};
		244 -> {rpl, stats_hline};
		251 -> {rpl, l_user_client};
		252 -> {rpl, l_user_op};
		253 -> {rpl, l_user_unknown};
		254 -> {rpl, l_user_channels};
		255 -> {rpl, l_user_me};
		256 -> {rpl, admin_me};
		257 -> {rpl, admin_loc_1};
		258 -> {rpl, admin_loc_2};
		259 -> {rpl, admin_email};
		261 -> {rpl, trace_log};
		300 -> {rpl, none};
		301 -> {rpl, away};
		302 -> {rpl, user_host};
		303 -> {rpl, is_on};
		305 -> {rpl, un_away};
		306 -> {rpl, now_away};
		311 -> {rpl, whois_user};
		312 -> {rpl, whois_server};
		313 -> {rpl, whois_operator};
		314 -> {rpl, who_was_user};
		315 -> {rpl, end_of_who};
		317 -> {rpl, whois_idle};
		318 -> {rpl, end_of_whois};
		319 -> {rpl, whois_channels};
		321 -> {rpl, list_start};
		322 -> {rpl, list};
		323 -> {rpl, list_end};
		324 -> {rpl, channel_mode_is};
		331 -> {rpl, no_topic};
		332 -> {rpl, topic};
		341 -> {rpl, inviting};
		342 -> {rpl, summoning};
		351 -> {rpl, version};
		352 -> {rpl, who_reply};
		353 -> {rpl, nam_reply};
		364 -> {rpl, links};
		365 -> {rpl, end_of_links};
		366 -> {rpl, end_of_names};
		367 -> {rpl, ban_list};
		368 -> {rpl, end_of_banlist};
		369 -> {rpl, end_of_who_was};
		371 -> {rpl, info};
		372 -> {rpl, motd};
		374 -> {rpl, end_of_info};
		375 -> {rpl, motd_start};
		376 -> {rpl, end_of_motd};
		381 -> {rpl, youre_oper};
		382 -> {rpl, rehashing};
		391 -> {rpl, time_};
		392 -> {rpl, users_start};
		393 -> {rpl, users};
		394 -> {rpl, end_of_users};
		395 -> {rpl, no_users};
		401 -> {err, no_such_nick};
		402 -> {err, no_such_server};
		403 -> {err, no_such_channel};
		404 -> {err, cannot_send_to_chan};
		405 -> {err, too_many_channels};
		406 -> {err, was_no_suchnick};
		407 -> {err, too_many_targets};
		409 -> {err, no_origin};
		411 -> {err, no_recipient};
		412 -> {err, no_text_to_send};
		413 -> {err, no_top_level};
		414 -> {err, wild_top_level};
		421 -> {err, unknown_command};
		422 -> {err, no_motd};
		423 -> {err, no_admin_info};
		424 -> {err, file_error};
		431 -> {err, no_nickname_given};
		432 -> {err, erroneus_nickname};
		433 -> {err, nickname_in_use};
		436 -> {err, nick_collision};
		441 -> {err, usernot_in_channel};
		442 -> {err, not_on_channel};
		443 -> {err, user_on_channel};
		444 -> {err, no_login};
		445 -> {err, summon_disabled};
		446 -> {err, users_disabled};
		451 -> {err, not_registered};
		461 -> {err, need_more_params};
		462 -> {err, already_registered};
		463 -> {err, no_perm_for_host};
		464 -> {err, passwd_mismatch};
		465 -> {err, youre_banned_creep};
		467 -> {err, key_set};
		471 -> {err, channel_is_full};
		472 -> {err, unknown_mode};
		473 -> {err, invite_only_chan};
		474 -> {err, banned_from_chan};
		475 -> {err, bad_channel_key};
		481 -> {err, no_privileges};
		482 -> {err, chan_o_privs_needed};
		483 -> {err, cant_kill_server};
		491 -> {err, no_oper_host};
		501 -> {err, u_mode_unknown_flag};
		502 -> {err, users_dont_match};
		_ -> {unknown, Num}
	end.