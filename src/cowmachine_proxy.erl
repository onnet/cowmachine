%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2016 Marc Worrell
%%
%% @doc Middleware to update proxy settings in the Cowboy Req

%% Copyright 2016 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(cowmachine_proxy).
-author("Marc Worrell <marc@worrell.nl").

-behaviour(cowboy_middleware).

-export([
    execute/2,
    update_req/1
]).

-include_lib("cowlib/include/cow_parse.hrl").

%% @doc Cowboy middleware, route the new request. Continue with the cowmachine,
%%      requests a redirect or return a 400 on an unknown host.
-spec execute(Req, Env) -> {ok, Req, Env} | {stop, Req}
    when Req::cowboy_req:req(), Env::cowboy_middleware:env().
execute(Req, Env) ->
    {ok, update_req(Req), Env}.

-spec update_req(cowboy_req:req()) -> cowboy_req:req().
update_req(Req) ->
    case cowboy_req:header(<<"forwarded">>, Req) of
        undefined ->
            case cowboy_req:header(<<"x-forwarded-for">>, Req) of
                undefined ->
                    update_req_direct(Req);
                XForwardedFor ->
                    update_req_old_proxy(XForwardedFor, Req)
            end;
        Forwarded ->
            update_req_proxy(Forwarded, Req)
    end.

%% @doc Fetch the metadata from the request itself
update_req_direct(Req) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    Req#{
        cowmachine_proxy => false,
        cowmachine_forwarded_host => parse_host(cowboy_req:header(<<"host">>, Req)),
        cowmachine_forwarded_port => cowboy_req:port(Req),
        cowmachine_forwarded_proto => cowboy_req:scheme(Req),
        cowmachine_remote_ip => Peer,
        cowmachine_remote => list_to_binary(inet_parse:ntoa(Peer))
    }.

%% @doc Handle the "Forwarded" header, added by the proxy.
update_req_proxy(Forwarded, Req) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    case is_trusted_proxy(Peer) of
        true -> 
            Props = parse_forwarded(Forwarded),
            {Remote, RemoteAdr} = case proplists:get_value(<<"for">>, Props) of
                        undefined -> 
                            {list_to_binary(inet_parse:ntoa(Peer)), Peer};
                        For ->
                            parse_for(For, Req)
                     end,
            Proto = proplists:get_value(<<"proto">>, Props, <<"http">>), 
            Host = case proplists:get_value(<<"host">>, Props) of
                        undefined -> cowboy_req:header(<<"host">>, Req);
                        XHost -> XHost
                   end,
            Port = case proplists:get_value(<<"port">>, Props) of
                        undefined ->
                            case Proto of
                                <<"https">> -> 443;
                                _ -> 80
                            end;
                        XPort -> z_convert:to_integer(XPort)
                   end,
            Req#{
                cowmachine_proxy => true,
                cowmachine_forwarded_host => parse_host(Host),
                cowmachine_forwarded_port => Port,
                cowmachine_forwarded_proto => Proto,
                cowmachine_remote_ip => Remote,
                cowmachine_remote => RemoteAdr
            };
        false ->
            lager:error("Proxy header 'Forwarded' from untrusted peer ~s", [inet_parse:ntoa(Peer)]),
            update_req_direct(Req)
    end.

%% @doc Handle the "X-Forwarded-For" header, added by the proxy.
update_req_old_proxy(XForwardedFor, Req) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    case is_trusted_proxy(Peer) of
        true ->
            FwdFor = z_string:trim(lists:last(binary:split(XForwardedFor, <<",">>, [global]))),
            {Remote, RemoteAdr} = parse_for(FwdFor, Req),
            Proto = case trim(cowboy_req:header(<<"x-forwarded-proto">>, Req)) of
                        undefined -> <<"http">>;
                        XProto -> XProto
                    end,
            Host = case cowboy_req:header(<<"x-forwarded-host">>, Req) of
                        undefined -> cowboy_req:header(<<"host">>, Req);
                        XHost -> XHost
                   end,
            Port = case cowboy_req:header(<<"x-forwarded-port">>, Req) of
                        undefined ->
                            case Proto of
                                <<"https">> -> 443;
                                _ -> 80
                            end;
                        XPort -> z_convert:to_integer(XPort)
                   end,
            Req#{
                cowmachine_proxy => true,
                cowmachine_forwarded_host => parse_host(Host),
                cowmachine_forwarded_port => Port,
                cowmachine_forwarded_proto => Proto,
                cowmachine_remote_ip => Remote,
                cowmachine_remote => RemoteAdr
            };
        false ->
            lager:error("Proxy header 'X-Forwarded-For' from untrusted peer ~s", [inet_parse:ntoa(Peer)]),
            update_req_direct(Req)
    end.

trim(undefined) -> undefined;
trim(S) -> z_string:trim(S).

parse_host(undefined) ->
    undefined;
parse_host(Host) ->
    {Host1, _} = cow_http_hd:parse_host(Host),
    sanitize_host(Host1).

parse_for(undefined, Req) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    {list_to_binary(inet_parse:ntoa(Peer)), Peer};
parse_for(<<$[, Rest/binary>>, _Req) ->
    IP6 = hd(binary:split(Rest, <<"]">>)),
    {ok, Adr} = inet_parse:address(binary_to_list(IP6)),
    {Adr, IP6};
parse_for(For, Req) ->
    case inet_parse:address(binary_to_list(For)) of
        {ok, Adr} ->
            {Adr, For};
        {error, _} -> 
            % Not an IP address, take the Proxy address
            {Peer, _Port} = cowboy_req:peer(Req),
            {Peer, sanitize(For)}
    end.

sanitize(For) ->
    sanitize(For, <<>>).

sanitize(<<>>, Acc) -> Acc;
sanitize(<<C, Rest/binary>>, Acc) when ?IS_URI_UNRESERVED(C) -> sanitize(Rest, <<Acc/binary, C>>);
sanitize(<<_, Rest/binary>>, Acc) -> sanitize(Rest, <<Acc/binary, $->>).

-spec parse_forwarded(binary()) -> [{binary(), binary()}].
parse_forwarded(Header) when is_binary(Header) ->
    forwarded_list(Header, []).

forwarded_list(<<>>, Acc) -> lists:reverse(Acc);
forwarded_list(<<$,, R/bits>>, _Acc) -> forwarded_list(R, []);
forwarded_list(<< C, R/bits >>, Acc) when ?IS_WS(C) -> forwarded_list(R, Acc);
forwarded_list(<< $;, R/bits >>, Acc) -> forwarded_list(R, Acc);
forwarded_list(<< C, R/bits >>, Acc) when ?IS_ALPHANUM(C) -> forwarded_pair(R, Acc, << (lower(C)) >>).

forwarded_pair(<< C, R/bits >>, Acc, T) when ?IS_ALPHANUM(C) -> forwarded_pair(R, Acc, << T/binary, (lower(C)) >>);
forwarded_pair(R, Acc, T) -> forwarded_pair_eq(R, Acc, T).

forwarded_pair_eq(<< C, R/bits >>, Acc, T) when ?IS_WS(C) -> forwarded_pair_eq(R, Acc, T);
forwarded_pair_eq(<< $=, R/bits >>, Acc, T) -> forwarded_pair_value(R, Acc, T).

forwarded_pair_value(<< C, R/bits>>, Acc, T) when ?IS_WS(C) -> forwarded_pair_value(R, Acc, T);
forwarded_pair_value(<< $", R/bits>>, Acc, T) -> forwarded_pair_value_quoted(R, Acc, T, <<>>);
forwarded_pair_value(<< C, R/bits>>, Acc, T) -> forwarded_pair_value_token(R, Acc, T, << (lower(C)) >>).

forwarded_pair_value_token(<< C, R/bits>>, Acc, T, V) when ?IS_TOKEN(C) -> forwarded_pair_value_token(R, Acc, T, << V/binary, (lower(C)) >>);
forwarded_pair_value_token(R, Acc, T, V) -> forwarded_list(R, [{T, V}|Acc]).

forwarded_pair_value_quoted(<< $", R/bits >>, Acc, T, V) -> forwarded_list(R, [{T, V}|Acc]);
forwarded_pair_value_quoted(<< $\\, C, R/bits >>, Acc, T, V) -> forwarded_pair_value_quoted(R, Acc, T, << V/binary, (lower(C)) >>);
forwarded_pair_value_quoted(<< C, R/bits >>, Acc, T, V) -> forwarded_pair_value_quoted(R, Acc, T, << V/binary, (lower(C)) >>).

lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

%% @doc Check if the given proxy is trusted.
is_trusted_proxy(Peer) ->
    case application:get_env(cowmachine, proxy_whitelist) of
        {ok, ProxyWhitelist} ->
            is_trusted_proxy(ProxyWhitelist, Peer);
        undefined ->
            is_trusted_proxy(local, Peer)
    end.

is_trusted_proxy(none, _Peer) ->
    false;
is_trusted_proxy(any, _Peer) ->
    true;
is_trusted_proxy(local, Peer) ->
    is_local(Peer);
is_trusted_proxy(ip_whitelist, Peer) ->
    case application:get_env(cowmachine, ip_whitelist) of
        {ok, Whitelist} ->
            is_trusted_proxy(Whitelist, Peer);
        undefined ->
            is_trusted_proxy(local, Peer)
    end;
is_trusted_proxy(Whitelist, Peer) when is_list(Whitelist) ->
    %% @todo hook into the routines checking ip_whitelist in zotonic
    false.


%% Check if matching "127.0.0.0/8,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,169.254.0.0/16,::1,fd00::/8,fe80::/10"
is_local({127,_,_,_}) -> true;
is_local({10,_,_,_}) -> true;
is_local({192,168,_,_}) -> true;
is_local({169,254,_,_}) -> true;
is_local({172,X,_,_}) when X >= 16, X =< 31 -> true;
is_local({X,_,_,_,_,_,_,_}) when X >= 16#fd00, X =< 16#fdff -> true;
is_local({X,_,_,_,_,_,_,_}) when X >= 16#fe80, X =< 16#fecf -> true;
is_local(_) -> false.


% Extra host sanitization as cowboy is too lenient.
% Cowboy did already do the lowercasing of the hostname
sanitize_host(<<$[, _/binary>> = Host) ->
    % IPv6 address, sanitized by cowboy
    Host;
sanitize_host(Host) ->
    sanitize_host(Host, <<>>).

sanitize_host(<<>>, Acc) -> Acc;
sanitize_host(<<C, Rest/binary>>, Acc) when C >= $a, C =< $z -> sanitize_host(Rest, <<Acc/binary, C>>);
sanitize_host(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 -> sanitize_host(Rest, <<Acc/binary, C>>);
sanitize_host(<<$-, Rest/binary>>, Acc) -> sanitize_host(Rest, <<Acc/binary, $->>);
sanitize_host(<<$., Rest/binary>>, Acc) -> sanitize_host(Rest, <<Acc/binary, $.>>);
sanitize_host(<<$:, _/binary>>, Acc) -> Acc;
sanitize_host(<<_, Rest/binary>>, Acc) -> sanitize_host(Rest, <<Acc/binary, $->>).
