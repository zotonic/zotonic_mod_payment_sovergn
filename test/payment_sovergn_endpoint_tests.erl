%% @doc Endpoint selection must cover OAuth, API requests and token cache isolation.
-module(payment_sovergn_endpoint_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

endpoint_test() ->
    Cache = ets:new(sovergn_endpoint_test, [public]),
    meck:new([m_config, z_fetch, z_depcache, httpc, tls_certificate_check], [passthrough, no_link]),
    try
        meck:expect(m_config, get_value, fun(mod_payment_sovergn, Key, _) ->
            maps:get(Key, #{oauth_client_id => <<"client">>, oauth_client_secret => <<"secret">>})
        end),
        meck:expect(m_config, get_value, fun(mod_payment_sovergn, api_endpoint, Default, C) ->
            maps:get(api_endpoint, C#context.props, Default)
        end),
        meck:expect(z_depcache, get, fun(Key, _) ->
            case ets:lookup(Cache, Key) of [{_, Token}] -> {ok, Token}; [] -> undefined end
        end),
        meck:expect(z_depcache, set, fun(Key, Token, _, _) -> ets:insert(Cache, {Key, Token}), ok end),
        meck:expect(z_fetch, fetch_json, fun(post, Url, Payload, Options, C) ->
            Origin = payment_sovergn_api:api_origin(C),
            ?assertEqual(false, proplists:get_value(autoredirect, Options)),
            case Url of
                _ when Url =:= <<Origin/binary, "/oauth/token">> ->
                    {ok, token(Origin, maps:get(<<"scope">>, Payload))};
                _ ->
                    ?assertEqual(<<Origin/binary, "/v2/checkout_sessions">>, Url),
                    ?assertEqual(<<"Bearer ", Origin/binary>>, proplists:get_value(authorization, Options)),
                    {ok, #{}}
            end
        end),
        meck:expect(z_fetch, fetch_json, fun(Url, Options, C) ->
            Origin = payment_sovergn_api:api_origin(C),
            ?assertEqual(<<Origin/binary, "/v2/payments/status">>, Url),
            ?assertEqual(<<"Bearer ", Origin/binary>>, proplists:get_value(authorization, Options)),
            {ok, #{}}
        end),
        meck:expect(tls_certificate_check, options, fun(_) -> [{verify, verify_peer}] end),
        meck:expect(httpc, request, fun(post, {Url, _, _, Body}, Options, _) ->
            ?assertEqual(false, proplists:get_value(autoredirect, Options)),
            Scope = proplists:get_value(<<"scope">>, cow_qs:parse_qs(Body)),
            ?assert(lists:member(Url, ["https://beta.sovergnllc.com/oauth/token", "https://sovergnllc.com/oauth/token"])),
            {ok, {{"HTTP/1.1", 200, "OK"}, [], z_json:encode(token(<<"diagnostic">>, Scope))}}
        end),
        Beta = #context{},
        Prod = #context{props = #{api_endpoint => <<"production">>}},
        ?assertEqual(<<"https://beta.sovergnllc.com">>, payment_sovergn_api:api_origin(Beta)),
        ?assertEqual(<<"https://sovergnllc.com">>, payment_sovergn_api:api_origin(Prod)),
        lists:foreach(fun(C) ->
            ?assertEqual({ok, #{}}, payment_sovergn_api:api_json(post,
                <<"/v2/checkout_sessions">>, #{}, <<"checkout_sessions:create">>, [], C)),
            ?assertEqual({ok, #{}}, payment_sovergn_api:api_json(get,
                <<"/v2/payments/status">>, undefined, <<"payment_status:read">>, [], C)),
            ?assertMatch({ok, [_, _]}, payment_sovergn_api:test_oauth(C))
        end, [Beta, Prod, Beta, Prod]),
        %% Two origins times two scopes. Switching back reuses only that origin's tokens.
        ?assertEqual(4, ets:info(Cache, size)),
        ?assertEqual(8, meck:num_calls(z_fetch, fetch_json, ['_', '_', '_', '_', '_'])),
        ?assertEqual(4, meck:num_calls(httpc, request, [post,
            {"https://sovergnllc.com/oauth/token", '_', '_', '_'}, '_', '_'])),
        ?assertError(invalid_api_endpoint, payment_sovergn_api:api_origin(
            #context{props = #{api_endpoint => <<"https://untrusted.example">>}}))
    after
        meck:unload([m_config, z_fetch, z_depcache, httpc, tls_certificate_check]),
        ets:delete(Cache)
    end.

token(Token, Scope) ->
    #{<<"access_token">> => Token, <<"token_type">> => <<"Bearer">>,
      <<"expires_in">> => 3600, <<"scope">> => Scope}.

configuration_field_test() ->
    {module, mod_payment_sovergn} = code:ensure_loaded(mod_payment_sovergn),
    meck:new([z_acl, z_module_manager, m_config], [passthrough, no_link]),
    try
        meck:expect(z_acl, is_admin_editable, fun(_) -> true end),
        meck:expect(m_config, set_value, fun(_, _, _, _) -> ok end),
        meck:expect(z_acl, is_allowed, fun(use, mod_admin_config, _) -> true end),
        meck:expect(z_module_manager, active, fun(_) -> [mod_payment_sovergn] end),
        meck:expect(m_config, get_value, fun(_, _, Default, _) -> Default end),
        {ok, {Fields, []}} = m_payment_config:m_get(
            [<<"fields">>, <<"mod_payment_sovergn">>], #{}, #context{}),
        [Field] = [F || #{key := api_endpoint} = F <- Fields],
        ?assertMatch(#{input := radio, value := <<"beta">>,
            options := [<<"beta">>, <<"production">>]}, Field),
        Values = [{atom_to_binary(maps:get(key, F)), z_convert:to_binary(maps:get(value, F))} || F <- Fields],
        Production = lists:keystore(<<"api_endpoint">>, 1, Values, {<<"api_endpoint">>, <<"production">>}),
        ?assertEqual(ok, m_payment_config:save(mod_payment_sovergn, Production, #context{})),
        ?assert(meck:called(m_config, set_value, [mod_payment_sovergn, api_endpoint, <<"production">>, '_'])),
        meck:reset(m_config),
        Invalid = lists:keystore(<<"api_endpoint">>, 1, Values, {<<"api_endpoint">>, <<"invalid">>}),
        ?assertEqual({error, invalid_config}, m_payment_config:save(mod_payment_sovergn, Invalid, #context{})),
        ?assertEqual(0, meck:num_calls(m_config, set_value, '_')),
        meck:expect(z_acl, is_allowed, fun(_, _, _) -> false end),
        ?assertEqual({error, eacces}, m_payment_config:save(mod_payment_sovergn, Production, #context{})),
        ?assertEqual(0, meck:num_calls(m_config, set_value, '_'))
    after
        meck:unload([z_acl, z_module_manager, m_config])
    end.
