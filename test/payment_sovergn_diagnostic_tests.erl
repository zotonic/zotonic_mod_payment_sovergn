%% @doc Shell diagnostics must not create payments or disclose provider responses.
-module(payment_sovergn_diagnostic_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

diagnostic_test() ->
    meck:new([m_config, httpc, tls_certificate_check], [passthrough, no_link]),
    try
        configure(#{}),
        meck:expect(tls_certificate_check, options, fun(<<"beta.sovergnllc.com">>) ->
            [{verify, verify_peer}]
        end),
        meck:expect(httpc, request, fun(post, {Url, Headers, CT, Body}, Options, HttpOptions) ->
            ?assertEqual("https://beta.sovergnllc.com/oauth/token", Url),
            ?assertEqual("application/x-www-form-urlencoded", CT),
            ?assertEqual("Basic " ++ binary_to_list(base64:encode(<<"client:secret">>)),
                proplists:get_value("authorization", Headers)),
            ?assertEqual(false, proplists:get_value(autoredirect, Options)),
            ?assertEqual([{verify, verify_peer}], proplists:get_value(ssl, Options)),
            ?assertEqual(20000, proplists:get_value(timeout, Options)),
            ?assertEqual(binary, proplists:get_value(body_format, HttpOptions)),
            Params = cow_qs:parse_qs(Body),
            ?assertEqual(<<"client_credentials">>, proplists:get_value(<<"grant_type">>, Params)),
            valid_reply(proplists:get_value(<<"scope">>, Params))
        end),
        Expected = {ok, #{environment => <<"test">>, oauth => verified,
            scopes => [<<"checkout_sessions:create">>, <<"payment_status:read">>],
            merchant_token => present, webhook_signing_secret => present}},
        ?assertEqual(Expected, mod_payment_sovergn:test(#context{})),
        ?assertEqual(Expected, mod_payment_sovergn:test(#context{})),
        %% Every invocation verifies both grants afresh; no token cache is used.
        ?assertEqual(4, meck:num_calls(httpc, request, '_')),
        lists:foreach(fun(Key) ->
            configure(#{Key => <<" \t ">>}),
            ?assertEqual({error, {configuration, [Key]}}, mod_payment_sovergn:test(#context{}))
        end, [merchant_token, oauth_client_id, oauth_client_secret, webhook_signing_secret]),
        configure(#{environment => <<"invalid">>}),
        ?assertEqual({error, {configuration, [environment]}}, mod_payment_sovergn:test(#context{})),
        ?assertEqual(4, meck:num_calls(httpc, request, '_')),
        configure(#{}),
        lists:foreach(fun({Reply, Reason}) ->
            meck:expect(httpc, request, fun(_, _, _, _) -> Reply end),
            ?assertEqual({error, {oauth, <<"checkout_sessions:create">>, Reason}},
                mod_payment_sovergn:test(#context{}))
        end, [
            {{ok, {{"HTTP/1.1", Code, "secret"}, [{"secret", "token"}], <<"secret token">>}},
                {http_status, Code}} || Code <- [301, 302, 401, 403, 429, 500]
        ] ++ [
            {json_reply(<<"not json: secret token">>), invalid_response},
            {valid_reply(<<"wrong_scope">>), invalid_response},
            {json_reply(z_json:encode(#{<<"access_token">> => <<"secret">>,
                <<"token_type">> => <<"Bearer">>, <<"expires_in">> => 0,
                <<"scope">> => <<"checkout_sessions:create">>})), invalid_response},
            {{error, timeout}, timeout},
            {{error, {failed_connect, <<"secret token">>}}, request_failed}
        ]),
        meck:expect(httpc, request, fun(_, _, _, _) -> error({secret, <<"token">>}) end),
        ?assertEqual({error, {oauth, <<"checkout_sessions:create">>, request_failed}},
            mod_payment_sovergn:test(#context{})),
        meck:expect(httpc, request, fun(_, {_, _, _, Body}, _, _) ->
            case proplists:get_value(<<"scope">>, cow_qs:parse_qs(Body)) of
                <<"checkout_sessions:create">> = Scope -> valid_reply(Scope);
                <<"payment_status:read">> -> {ok, {{"HTTP/1.1", 403, "Forbidden"}, [], <<"secret">>}}
            end
        end),
        ?assertEqual({error, {oauth, <<"payment_status:read">>, {http_status, 403}}},
            mod_payment_sovergn:test(#context{}))
    after
        meck:unload([m_config, httpc, tls_certificate_check])
    end.

configure(Overrides) ->
    Config = maps:merge(#{environment => <<"test">>, merchant_token => <<"merchant">>,
        oauth_client_id => <<"client">>, oauth_client_secret => <<"secret">>,
        webhook_signing_secret => <<"webhook-secret">>}, Overrides),
    meck:expect(m_config, get_value, fun(mod_payment_sovergn, Key, #context{}) -> maps:get(Key, Config) end).

valid_reply(Scope) ->
    json_reply(z_json:encode(#{<<"access_token">> => <<"secret-access-token">>,
        <<"token_type">> => <<"Bearer">>, <<"expires_in">> => 3600, <<"scope">> => Scope})).

json_reply(Body) -> {ok, {{"HTTP/1.1", 200, "OK"}, [], Body}}.
