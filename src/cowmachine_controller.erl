%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2009 Basho Technologies
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

-module(cowmachine_controller).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-author('Marc Worrell <marc@worrell.nl>').

-export([
    do/3
]).

-include("cowmachine_state.hrl").

default(service_available) ->
    true;
default(resource_exists) ->
    true;
default(auth_required) ->
    true;
default(is_authorized) ->
    true;
default(forbidden) ->
    false;
default(upgrades_provided) ->
    [];
default(allow_missing_post) ->
    false;
default(malformed_request) ->
    false;
default(uri_too_long) ->
    false;
default(known_content_type) ->
    true;
default(valid_content_headers) ->
    true;
default(valid_entity_length) ->
    true;
default(options) ->
    [];
default(allowed_methods) ->
    [<<"GET">>, <<"HEAD">>];
default(known_methods) ->
    [<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>, <<"DELETE">>, <<"TRACE">>, <<"CONNECT">>, <<"OPTIONS">>];
default(content_types_provided) ->
    [{<<"text/html">>, to_html}];
default(content_types_accepted) ->
    [];
default(delete_resource) ->
    false;
default(delete_completed) ->
    true;
default(post_is_create) ->
    false;
default(create_path) ->
    undefined;
default(base_uri) ->
    undefined;
default(process_post) ->
    false;
default(language_available) ->
    true;

% The default setting is needed for non-charset responses such as image/png
% An example of how one might do actual negotiation:
%    [<<"iso-8859-1">>, <<"utf-8">>];
default(charsets_provided) ->
    no_charset; % this atom causes charset-negotation to short-circuit

% The content variations available to the controller.
default(content_encodings_provided) ->
    [<<"identity">>];

% How the content is transferred, this is handy for auto-gzip of GET-only resources.
% "identity" and "chunked" are always available to HTTP/1.1 clients.
% Example:
%    [{"gzip", fun(X) -> zlib:gzip(X) end}];
default(transfer_encodings_provided) ->
    [];

default(variances) ->
    [];
default(is_conflict) ->
    false;
default(multiple_choices) ->
    false;
default(previously_existed) ->
    false;
default(moved_permanently) ->
    false;
default(moved_temporarily) ->
    false;
default(last_modified) ->
    undefined;
default(expires) ->
    undefined;
default(generate_etag) ->
    undefined;
default(finish_request) ->
    true;
default(_) ->
    no_default.


%% @TODO Re-add logging code

do(Fun, #cmstate{controller=Controller}, Context) when is_atom(Fun) ->
    case erlang:function_exported(Controller, Fun, 1) of
        true ->
            Controller:Fun(Context);
        false ->
            case default(Fun) of
                no_default -> Controller:Fun(Context);
                Default -> {Default, Context}
            end
    end.

