-module(payment_sovergn_api_tests).

-include_lib("eunit/include/eunit.hrl").

amount_minor_units_test() ->
    ?assertEqual(1234, payment_sovergn_api:amount_minor_units(12.34, <<"EUR">>)),
    ?assertEqual(2500, payment_sovergn_api:amount_minor_units(25, <<"USD">>)).

idempotency_key_test() ->
    Key1 = payment_sovergn_api:idempotency_key(<<"payment-1">>),
    Key2 = payment_sovergn_api:idempotency_key(<<"payment-1">>),
    ?assertEqual(Key1, Key2),
    ?assertEqual(64, byte_size(Key1)),
    ?assertNotEqual(Key1, payment_sovergn_api:idempotency_key(<<"payment-2">>)).

eligible_contact_payment_test() ->
    ?assert(payment_sovergn_api:is_eligible_payment(#{
        <<"currency">> => <<"EUR">>,
        <<"amount">> => 25.0,
        <<"is_recurring_start">> => false,
        <<"email">> => <<"payer@example.test">>,
        <<"name_first">> => <<"Ada">>
    })).

eligible_referenced_payment_link_test() ->
    ?assert(payment_sovergn_api:is_eligible_payment(#{
        <<"currency">> => <<"USD">>,
        <<"amount">> => 25.0,
        <<"is_recurring_start">> => false,
        <<"props">> => #{
            <<"is_payment_link">> => true,
            <<"reference">> => <<"local-business-reference">>
        }
    })).

ineligible_payment_test() ->
    ?assertNot(payment_sovergn_api:is_eligible_payment(#{
        <<"currency">> => <<"GBP">>,
        <<"amount">> => 25.0,
        <<"email">> => <<"payer@example.test">>,
        <<"name_first">> => <<"Ada">>
    })),
    ?assertNot(payment_sovergn_api:is_eligible_payment(#{
        <<"currency">> => <<"EUR">>,
        <<"amount">> => 25.0,
        <<"email">> => <<"not-an-email">>,
        <<"name_first">> => <<"Ada">>
    })).

validate_checkout_response_test() ->
    Request = #{
        <<"merchantToken">> => <<"merchant-test">>,
        <<"merchantReference">> => <<"payment-1">>,
        <<"amount">> => 2500,
        <<"currency">> => <<"EUR">>,
        <<"environment">> => <<"test">>
    },
    Response = Request#{
        <<"checkoutSessionRef">> => <<"chk_test">>,
        <<"checkoutUrl">> => <<"https://checkout.sovergn.invalid/checkout/chk_test">>,
        <<"checkoutMode">> => <<"hosted">>,
        <<"decision">> => <<"ALLOW">>,
        <<"outcome">> => <<"checkout_ready">>,
        <<"providerBlind">> => true,
        <<"idempotencyStatus">> => <<"created">>
    },
    ?assertEqual(ok, payment_sovergn_api:validate_checkout_response(Response, Request)),
    ?assertEqual(
        {error, invalid_checkout_response},
        payment_sovergn_api:validate_checkout_response(
            Response#{<<"checkoutUrl">> => <<"https://evil.example/checkout/chk_test">>},
            Request)).
