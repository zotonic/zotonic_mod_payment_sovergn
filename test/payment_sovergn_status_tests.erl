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
