%% @copyright 2026 Driebit BV
%% @doc Tests for Sovergn payment status mapping.
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

-module(payment_sovergn_status_tests).

-include_lib("eunit/include/eunit.hrl").

api_status_test() ->
    ?assertEqual({ok, new}, payment_sovergn_status:guess_api_status(#{<<"status">> => <<"created">>})),
    ?assertEqual({ok, pending}, payment_sovergn_status:guess_api_status(#{<<"status">> => <<"ready">>})),
    ?assertEqual({ok, paid}, payment_sovergn_status:guess_api_status(#{<<"status">> => <<"completed">>})),
    ?assertEqual({ok, failed}, payment_sovergn_status:guess_api_status(#{<<"status">> => <<"failed">>})),
    ?assertEqual({ok, refunded}, payment_sovergn_status:guess_api_status(#{<<"status">> => <<"refunded">>})).

refund_state_precedes_status_test() ->
    ?assertEqual(
        {ok, refunded},
        payment_sovergn_status:guess_api_status(#{
            <<"status">> => <<"completed">>,
            <<"refundState">> => <<"completed">>
        })).

webhook_status_test() ->
    ?assertEqual(
        {set, paid},
        payment_sovergn_status:webhook_status(<<"payment.captured">>, <<"captured">>)),
    ?assertEqual(
        {set, failed},
        payment_sovergn_status:webhook_status(<<"payment.failed">>, <<"failed">>)),
    ?assertEqual(
        {set, refunded},
        payment_sovergn_status:webhook_status(<<"refund.resolved">>, <<"resolved">>)),
    ?assertEqual(
        {error, {unexpected_webhook_status, <<"payment.captured">>, <<"unknown">>}},
        payment_sovergn_status:webhook_status(<<"payment.captured">>, <<"unknown">>)),
    ?assertEqual(
        ignore,
        payment_sovergn_status:webhook_status(<<"settlement.paid">>, <<"paid">>)),
    ?assertEqual(
        ignore,
        payment_sovergn_status:webhook_status(<<"future.event">>, <<"future_status">>)).
