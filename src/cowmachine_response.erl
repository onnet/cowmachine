%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2009 Basho Technologies
%% Based on mochiweb_request.erl, which is Copyright 2007 Mochi Media, Inc.
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc Response functions, generate the response inclusive body and headers.
%% The body can be sourced from multiple sources. These sources include files,
%% binary files and functions.
%% The response body function handles range requests.

-module(cowmachine_response).
-author('Marc Worrell <marc@worrell.nl>').

-export([
     send_response/2,
     use_sendfile/0,
     server_header/0
     ]).

-define(IDLE_TIMEOUT, infinity).
-define(FILE_CHUNK_LENGTH, 65536).

server_header() ->
    case application:get_env(cowmachine, server_header) of
        {ok, Server} -> z_convert:to_binary(Server);
        undefined ->
            {ok, Version} = application:get_key(cowmachine, vsn),
            <<"CowMachine/", (z_convert:to_binary(Version))>>
    end.


use_sendfile() ->
    case application:get_env(cowmachine, use_sendfile) of
        undefined -> disable;
        {ok, disable} -> disable;
        {ok, erlang} -> erlang;
        {ok, yaws} -> 
            case sendfile:enabled() of
                true -> yaws;
                false -> disable
            end
    end.

-spec send_response(cowmachine_req:context(), Env) -> {ok, Req, Env} | {stop, Req}
    when Req::cowboy_req:req(), Env::cowboy_middleware:env().
send_response(Context, Env) ->
    Req = cowmachine_req:req(Context),
    HttpStatusCode = cowmachine_req:response_code(Req),
    Req1 = send_response_range(HttpStatusCode, Req),
    {ok, Req1, Env}.

%% --------------------------------------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------------------------------------

send_response_range(200, Req) ->
    {Range, Req1} = get_range(Req),
    case Range of
        undefined ->
            send_response_code(200, all, Req1);
        Ranges ->
            case get_resp_body_size(cowmachine_req:resp_body(Req1)) of
                {ok, Size, Body1} ->
                    Req2 = cowmachine_req:set_resp_body(Body1, Req1),
                    case range_parts(Ranges, Size) of
                        [] ->
                            % no valid ranges
                            % could be 416, for now we'll just return 200 and the whole body
                            send_response_code(200, all, Req2);
                        PartList ->
                            % error_logger:info_msg("PARTS ~p (~p)", [PartList, wrq:path(ReqData)]), 
                            ContentType = cowmachine_req:get_resp_header(<<"content-type">>, Req2), 
                            {RangeHeaders, Boundary} = make_range_headers(PartList, Size, ContentType),
                            Req3 = cowmachine_req:set_resp_headers(RangeHeaders, Req2),
                            send_response_code(206, {PartList, Size, Boundary, ContentType}, Req3)
                    end;
                {error, nosize} ->
                    send_response_code(200, all, Req1)
            end
    end;
send_response_range(Code, Req) ->
    send_response_code(Code, all, Req).

send_response_code(Code, Parts, Req) ->
    send_response_bodyfun(cowmachine_req:resp_body(Req), Code, Parts, Req).


send_response_bodyfun({device, IO}, Code, Parts, Req) ->
    Length = iodevice_size(IO),
    send_response_bodyfun({device, Length, IO}, Code, Parts, Req);
send_response_bodyfun({device, Length, IO}, Code, all, Req) ->
    Writer = fun() -> 
                Bytes = send_device_body(Req, Length, IO),
                _ = file:close(IO),
                Bytes
             end,
    start_response_stream(Code, Length, Writer, Req);
send_response_bodyfun({device, _Length, IO}, Code, Parts, Req) ->
    Writer = fun() -> 
                Bytes = send_device_body_parts(Req, Parts, IO),
                _ = file:close(IO),
                Bytes
             end,
    start_response_stream(Code, undefined, Writer, Req);
send_response_bodyfun({file, Filename}, Code, Parts, Req) ->
    Length = filelib:file_size(Filename),
    start_response_stream({file, Length, Filename}, Code, Parts, Req);
send_response_bodyfun({file, Length, Filename}, Code, all, Req) ->
    Writer = fun() -> send_file_body(Req, Length, Filename) end,
    start_response_stream(Code, Length, Writer, Req);
send_response_bodyfun({file, _Length, Filename}, Code, Parts, Req) ->
    Writer = fun() -> send_file_body_parts(Req, Parts, Filename) end,
    start_response_stream(Code, undefined, Writer, Req);
send_response_bodyfun({stream, StreamFun}, Code, all, Req) ->
    Writer = fun() -> send_stream_body(Req, StreamFun) end,
    start_response_stream(Code, undefined, Writer, Req);
send_response_bodyfun({stream, Size, Fun}, Code, all, Req) ->
    Writer = fun() -> send_stream_body(Req, Fun(0, Size-1)) end,
    start_response_stream(Code, undefined, Writer, Req);
send_response_bodyfun({writer, WriterFun}, Code, all, Req) ->
    Writer = fun() -> send_writer_body(Req, WriterFun) end,
    start_response_stream(Code, undefined, Writer, Req);
send_response_bodyfun(Body, Code, all, Req) ->
    Length = iolist_size(Body),
    start_response_stream(Code, Length, Body, Req);
send_response_bodyfun(Body, Code, Parts, Req) ->
    Writer = fun() -> send_parts(Req, Body, Parts) end,
    start_response_stream(Code, undefined, Writer, Req).


start_response_stream(Code, Length, FunOrBody, Req) ->
    Headers = response_headers(Code, Length, Req),
    case cowmachine_req:method(Req) of
        <<"HEAD">> ->
            % @todo Hack Alert!
            % At the moment cowboy 2.0 doesn't allow any HEAD processing
            % The normal cowboy reply would set the content-length to 0.
            StreamID = maps:get(streamid, Req),
            Pid = maps:get(pid, Req),
            Pid ! {{Pid, StreamID}, {response, Code, Headers, <<>>}},
            {ok, 0};
        _Method when is_function(FunOrBody) ->
            cowboy_req:reply(Code, Headers, {stream, undefined, FunOrBody}, Req);
        _Method when FunOrBody =:= undefined ->
            cowboy_req:reply(Code, Headers, <<>>, Req);
        _Method when is_list(FunOrBody); is_binary(FunOrBody) ->
            cowboy_req:reply(Code, Headers, FunOrBody, Req)
    end.

%% @todo Add the cookies!
response_headers(Code, Length, Req) ->
    Hdrs = cowmachine_req:get_resp_headers(Req),
    Hdrs1 = case Code of
        304 ->
            Hdrs;
        _ when is_integer(Length) -> 
            Hdrs#{<<"content-length">> => integer_to_binary(Length)};
        _ ->
            Hdrs
    end,
    Hdrs1#{ 
        <<"server">> => server_header(),
        <<"date">> => cowboy_clock:rfc1123()
    }.

send_stream_body(Req, {<<>>, done}) ->
    % @TODO: in cowboy this give a wrong termination with two 0 size chunks
    send_final_chunk(Req, <<>>);
send_stream_body(Req, {Data, done}) ->
    send_final_chunk(Req, Data);
send_stream_body(Req, {{file, Filename}, Next}) ->
    Length = filelib:file_size(Filename),
    send_stream_body(Req, {{file, Length, Filename}, Next});
send_stream_body(Req, {{file, 0, _Filename}, Next}) ->
    send_stream_body(Req, {<<>>, Next});
send_stream_body(Req, {{file, Size, Filename}, Next}) ->
    send_file_body(Req, Size, Filename),
    send_stream_body(Req, {<<>>, Next});
send_stream_body(Req, {<<>>, Next}) ->
    send_stream_body(Req, Next());
send_stream_body(Req, {[], Next}) ->
    send_stream_body(Req, Next());
send_stream_body(Req, {Data, Next}) ->
    send_chunk(Req, Data),
    send_stream_body(Req, Next()).

send_device_body(Req, Length, IO) ->
    send_file_body_loop(Req, 0, Length, IO).

send_file_body(Req, Length, Filename) ->
    {ok, FD} = file:open(Filename, [raw,binary]),
    try
        send_file_body_loop(Req, 0, Length, FD)
    after
        file:close(FD)
    end.

send_device_body_parts(Req, {[{From,Length}], _Size, _Boundary, _ContentType}, IO) ->
    {ok, _} = file:position(IO, From), 
    send_file_body_loop(Req, 0, Length, IO);
send_device_body_parts(Req, {Parts, Size, Boundary, ContentType}, IO) ->
    lists:foreach(
        fun({From,Length}) ->
            {ok, _} = file:position(IO, From), 
            send_chunk(Req, part_preamble(Boundary, ContentType, From, Length, Size)),
            send_file_body_loop(Req, 0, Length, IO),
            send_chunk(Req, <<"\r\n">>)
        end,
        Parts),
    send_final_chunk(Req, end_boundary(Boundary)).

send_file_body_parts(Req, Parts, Filename) ->
    {ok, FD} = file:open(Filename, [raw,binary]),
    try
        send_device_body_parts(Req, Parts, FD)
    after
        file:close(FD)
    end.

send_parts(Req, Bin, {[{From,Length}], _Size, _Boundary, _ContentType}) ->
    send_chunk(Req, binary:part(Bin,From,Length));
send_parts(Req, Bin, {Parts, Size, Boundary, ContentType}) ->
    lists:foreach(
        fun({From,Length}) ->
            Part = [
                part_preamble(Boundary, ContentType, From, Length, Size),
                Bin,
                <<"\r\n">>
            ],
            send_chunk(Req, Part)
        end,
        Parts),
    send_final_chunk(Req, end_boundary(Boundary)).


send_file_body_loop(_Req, Offset, Size, _Device) when Offset =:= Size ->
    ok;
send_file_body_loop(Req, Offset, Size, Device) when Size - Offset =< ?FILE_CHUNK_LENGTH ->
    {ok, Data} = file:read(Device, Size - Offset),
    send_final_chunk(Req, Data);
send_file_body_loop(Req, Offset, Size, Device) ->
    {ok, Data} = file:read(Device, ?FILE_CHUNK_LENGTH),
    send_chunk(Req, Data),
    send_file_body_loop(Req, Offset+?FILE_CHUNK_LENGTH, Size, Device).

send_writer_body(Req, BodyFun) ->
    BodyFun(fun(Data, false) -> send_chunk(Req, Data);
               (Data, true) -> send_final_chunk(Req, Data)
            end),
    send_final_chunk(Req, <<>>).

send_chunk(_Req, <<>>) -> ok;
send_chunk(_Req, []) -> ok;
send_chunk(Req, Data) ->
    Data1 = iolist_to_binary(Data),
    cowboy_req:send_body(Data1, nofin, Req).

send_final_chunk(Req, Data) ->
    Data1 = iolist_to_binary(Data),
    cowboy_req:send_body(Data1, fin, Req).

-spec get_range(cowboy_req:req()) -> {undefined|[{integer()|none,integer()|none}], cowboy_req:req()}.
get_range(Req) ->
    case maps:get(cowmachine_range_ok, Req) of
        false ->
            {undefined, Req#{ cowmachine_range => undefined }};
        true ->
            case cowboy_req:get_header(<<"range">>, Req) of
                undefined ->
                    {undefined, Req#{ cowmachine_range => undefined }};
                RawRange ->
                    Range = parse_range_request(RawRange),
                    {Range, Req#{ cowmachine_range => Range }}
            end
    end.

-spec parse_range_request(binary()|undefined) -> undefined | [{integer()|none,integer()|none}].
parse_range_request(<<"bytes=", RangeString/binary>>) ->
    try
        Ranges = binary:split(RangeString, <<",">>, [global]),
        lists:map(
            fun (<<"-", V/binary>>)  ->
                   {none, binary_to_integer(V)};
                (R) ->
                    case binary:split(R, <<"-">>) of
                        [S1, S2] -> {binary_to_integer(S1), binary_to_integer(S2)};
                        [S] -> {binary_to_integer(S), none}
                    end
          end,
          Ranges)
    catch
        _:_ ->
            % Invalid range header, ignore silently
            undefined
    end;
parse_range_request(_) ->
    undefined.

% Map request ranges to byte ranges, taking the total body length into account.
-spec range_parts([{integer()|none,integer()|none}], integer()) -> [{integer(),integer()}].
range_parts(Ranges, Size) ->
    Ranges1 = [ range_skip_length(Spec, Size) || Spec <- Ranges ],
    [ R || R <- Ranges1, R =/= invalid_range ].

range_skip_length({none, R}, Size) when R =< Size, R >= 0 ->
    {Size - R, R};
range_skip_length({none, _OutOfRange}, Size) ->
    {0, Size};
range_skip_length({R, none}, Size) when R >= 0, R < Size ->
    {R, Size - R};
range_skip_length({_OutOfRange, none}, _Size) ->
    invalid_range;
range_skip_length({Start, End}, Size) when 0 =< Start, Start =< End, End < Size ->
    {Start, End - Start + 1};
range_skip_length({_OutOfRange, _End}, _Size) ->
    invalid_range.

-spec get_resp_body_size(cowmachine_req:resp_body()) -> 
          {ok, integer(), cowmachine_req:resp_body()}
        | {error, nosize}.
get_resp_body_size({device, Size, _} = Body) ->
    {ok, Size, Body};
get_resp_body_size({device, IO}) ->
    Length = iodevice_size(IO),
    {ok, Length, {device, Length, IO}};
get_resp_body_size({file, Size, _} = Body) ->
    {ok, Size, Body};
get_resp_body_size({file, Filename}) ->
    Length = filelib:file_size(Filename),
    {ok, Length, {file, Length, Filename}};
get_resp_body_size(B) when is_binary(B) ->
    {ok, size(B), B};
get_resp_body_size(L) when is_list(L) ->
    B = iolist_to_binary(L),
    {ok, size(B), B};
get_resp_body_size(_) ->
    {error, nosize}.

make_range_headers([{Start, Length}], Size, _ContentType) ->
    HeaderList = [{<<"accept-ranges">>, <<"bytes">>},
                  {<<"content-range">>, iolist_to_binary([
                            "bytes ", make_io(Start), "-", make_io(Start+Length-1), "/", make_io(Size)])},
                  {<<"content-length">>, integer_to_binary(Length)}],
    {HeaderList, none};
make_range_headers(Parts, Size, ContentType) when is_list(Parts) ->
    Boundary = iolist_to_binary(mochihex:to_hex(rand_bytes(8))),
    Lengths = [
        iolist_size(part_preamble(Boundary, ContentType, Start, Length, Size)) + Length + 2
        || {Start,Length} <- Parts
    ],
    TotalLength = lists:sum(Lengths) + iolist_size(end_boundary(Boundary)), 
    HeaderList = [{<<"accept-ranges">>, <<"bytes">>},
                  {<<"content-type">>, <<"multipart/byteranges; boundary=", Boundary/binary>>},
                  {<<"content-length">>, integer_to_binary(TotalLength)}],
    {HeaderList, Boundary}.

part_preamble(Boundary, CType, Start, Length, Size) ->
    [boundary(Boundary),
     <<"content-type: ">>, CType,
     <<"\r\ncontent-range: bytes ">>, 
        integer_to_binary(Start), <<"-">>, integer_to_binary(Start+Length-1), 
        <<"/">>, integer_to_binary(Size),
     <<"\r\n\r\n">>].

boundary(B)     -> <<"--", B/binary, "\r\n">>.
end_boundary(B) -> <<"--", B/binary, "--\r\n">>.

make_io(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
make_io(Integer) when is_integer(Integer) ->
    integer_to_list(Integer);
make_io(Io) when is_list(Io); is_binary(Io) ->
    Io.


-spec iodevice_size(file:io_device()) -> integer().
iodevice_size(IoDevice) ->
    {ok, Size} = file:position(IoDevice, eof),
    {ok, 0} = file:position(IoDevice, bof),
    Size.

%% @doc Return N random bytes. This falls back to the pseudo random version of rand_uniform 
%% if strong_rand_bytes fails.
-spec rand_bytes(integer()) -> binary().
rand_bytes(N) when N > 0 ->
    try 
        crypto:strong_rand_bytes(N)
    catch
        error:low_entropy ->
            lager:info("Crypto is low on entropy"),
            list_to_binary([ crypto:rand_uniform(0,256) || _X <- lists:seq(1, N) ])
    end.
