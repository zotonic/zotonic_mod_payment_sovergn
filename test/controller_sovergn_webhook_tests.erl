-module(controller_sovergn_webhook_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

delivery_test_without_reference_test() ->
    ?assertMatch({true, _}, process(test_payload())).

delivery_test_repeated_test() ->
    ?assertMatch({true, _}, process(test_payload())),
    ?assertMatch({true, _}, process(test_payload())).

delivery_test_event_id_mismatch_test() ->
    ?assertMatch({{halt, 400}, _},
        process((test_payload())#{ <<"event_id">> => <<"evt_other">> })).

real_event_without_reference_test() ->
    ?assertMatch({{halt, 400}, _},
        process((test_payload())#{ <<"capsule_id">> => <<"cap_real">> })).

empty_test_capsule_test() ->
    ?assertMatch({{halt, 400}, _},
        process((test_payload())#{ <<"capsule_id">> => <<"test_cap_">> })).

invalid_json_test() ->
    ?assertMatch({{halt, 400}, _}, process_body(<<"{">>)).

non_object_json_test() ->
    ?assertMatch({{halt, 400}, _}, process_body(<<"[]">>)).

test_payload() ->
    #{
        <<"event_id">> => <<"evt_test">>,
        <<"event_type">> => <<"payment.captured">>,
        <<"capsule_id">> => <<"test_cap_123">>,
        <<"occurred_at">> => <<"2026-10-01T07:08:24.984Z">>,
        <<"amount">> => 100,
        <<"currency">> => <<"USD">>,
        <<"status">> => <<"captured">>
    }.

process(Payload) ->
    process_body(z_json:encode(Payload)).

process_body(Body) ->
    Context = z_context:set(sovergn_webhook_event_id, <<"evt_test">>,
        z_context:set(sovergn_webhook_body, Body, #context{})),
    controller_sovergn_webhook:process(<<"POST">>, undefined, undefined, Context).
