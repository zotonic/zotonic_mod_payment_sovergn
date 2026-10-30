%% @copyright 2026 Driebit BV
%% @doc Tests for Sovergn webhook verification.
%% @end

%% Copyright 2026 Driebit BV
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

-module(payment_sovergn_webhook_tests).

-include_lib("eunit/include/eunit.hrl").

valid_signature_test() ->
    Timestamp = <<"2026-08-31T10:00:00.000Z">>,
    EventId = <<"evt_test_123">>,
    Body = <<"{\"event_id\":\"evt_test_123\"}">>,
    Secret = <<"test-secret">>,
    Signature = signature(Timestamp, EventId, Body, Secret),
    {ok, Now} = payment_sovergn_webhook:parse_timestamp(Timestamp),
    ?assertEqual(
        ok,
        payment_sovergn_webhook:verify(
            <<"aop-hmac-sha256-v1">>, EventId, Timestamp,
            Signature, Body, Secret, Now)).

invalid_signature_test() ->
    Timestamp = <<"2026-08-31T10:00:00.000Z">>,
    {ok, Now} = payment_sovergn_webhook:parse_timestamp(Timestamp),
    ?assertEqual(
        {error, invalid_signature},
        payment_sovergn_webhook:verify(
            <<"aop-hmac-sha256-v1">>, <<"evt_1">>, Timestamp,
            <<"00">>, <<"{}">>, <<"secret">>, Now)).

stale_timestamp_test() ->
    Timestamp = <<"2026-08-31T10:00:00.000Z">>,
    EventId = <<"evt_1">>,
    Body = <<"{}">>,
    Secret = <<"secret">>,
    Signature = signature(Timestamp, EventId, Body, Secret),
    {ok, EventTime} = payment_sovergn_webhook:parse_timestamp(Timestamp),
    ?assertEqual(
        {error, stale_timestamp},
        payment_sovergn_webhook:verify(
            <<"aop-hmac-sha256-v1">>, EventId, Timestamp,
            Signature, Body, Secret, EventTime + 301)).

noncanonical_timestamp_test() ->
    ?assertEqual(
        {error, timestamp},
        payment_sovergn_webhook:parse_timestamp(<<"2026-08-31T10:00:00Z">>)).

uppercase_signature_test() ->
    Timestamp = <<"2026-08-31T10:00:00.000Z">>,
    EventId = <<"evt_1">>,
    Body = <<"{}">>,
    Secret = <<"secret">>,
    Signature = z_string:to_upper(signature(Timestamp, EventId, Body, Secret)),
    {ok, Now} = payment_sovergn_webhook:parse_timestamp(Timestamp),
    ?assertEqual(
        {error, invalid_signature},
        payment_sovergn_webhook:verify(
            <<"aop-hmac-sha256-v1">>, EventId, Timestamp,
            Signature, Body, Secret, Now)).

signature(Timestamp, EventId, Body, Secret) ->
    Data = <<Timestamp/binary, $., EventId/binary, $., Body/binary>>,
    z_string:to_lower(z_utils:hex_encode(crypto:mac(hmac, sha256, Secret, Data))).
