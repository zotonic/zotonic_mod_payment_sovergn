%% @copyright 2026
%% @doc Mapping from Sovergn states to mod_payment states.
%%
%% The status-endpoint vocabulary and webhook event/status combinations follow
%% the Sovergn merchant API contract and must match exactly.
%% @end

-module(payment_sovergn_status).

-export([
    guess_api_status/1,
    webhook_status/2
]).

-spec guess_api_status(map()) -> {ok, atom()} | {error, term()}.
guess_api_status(#{ <<"refundState">> := <<"completed">> }) ->
    {ok, refunded};
guess_api_status(#{ <<"status">> := <<"created">> }) ->
    {ok, new};
guess_api_status(#{ <<"status">> := <<"ready">> }) ->
    {ok, pending};
guess_api_status(#{ <<"status">> := <<"completed">> }) ->
    {ok, paid};
guess_api_status(#{ <<"status">> := <<"failed">> }) ->
    {ok, failed};
guess_api_status(#{ <<"status">> := <<"refunded">> }) ->
    {ok, refunded};
guess_api_status(#{ <<"status">> := Status }) ->
    {error, {unknown_sovergn_status, Status}};
guess_api_status(_) ->
    {error, missing_sovergn_status}.

%% Settlement is an accounting event and does not change the payer-facing
%% payment state.
-spec webhook_status(binary(), binary()) ->
    {set, atom()} | ignore | {error, term()}.
webhook_status(<<"payment.captured">>, <<"captured">>) ->
    {set, paid};
webhook_status(<<"payment.failed">>, <<"failed">>) ->
    {set, failed};
webhook_status(<<"refund.resolved">>, <<"resolved">>) ->
    {set, refunded};
webhook_status(<<"settlement.paid">>, <<"paid">>) ->
    ignore;
webhook_status(EventType, Status)
    when EventType =:= <<"payment.captured">>;
         EventType =:= <<"payment.failed">>;
         EventType =:= <<"refund.resolved">>;
         EventType =:= <<"settlement.paid">> ->
    {error, {unexpected_webhook_status, EventType, Status}};
webhook_status(_EventType, _Status) ->
    %% Forward-compatible no-op: a signed, otherwise valid event which this
    %% module does not consume must not trigger an endless webhook retry loop.
    ignore.
