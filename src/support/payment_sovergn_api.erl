%% @copyright 2026
%% @doc Sovergn OAuth, checkout-session, and payment-status API adapter.
%% @end

-module(payment_sovergn_api).

-export([
    create/2,
    sync/2,

    amount_minor_units/2,
    idempotency_key/1,
    is_eligible_payment/1,
    validate_checkout_response/2
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("zotonic_mod_payment/include/payment.hrl").

%% TODO(sovergn): Replace these placeholders after Sovergn confirms the exact
%% production API host and hosted-checkout origin/path.
-define(API_ORIGIN, <<"https://api.sovergn.invalid">>).
-define(CHECKOUT_ORIGIN, <<"https://checkout.sovergn.invalid">>).
-define(CHECKOUT_PATH_PREFIX, <<"/checkout/">>).

-define(TIMEOUT, 20000).
-define(SCOPE_CHECKOUT_CREATE, <<"checkout_sessions:create">>).
-define(SCOPE_PAYMENT_STATUS, <<"payment_status:read">>).

-spec create(integer(), z:context()) ->
    {ok, #payment_psp_handler{}} | {error, term()}.
create(PaymentId, Context) ->
    case m_payment:get(PaymentId, Context) of
        {ok, Payment} ->
            create_payment(Payment, Context);
        {error, _} = Error ->
            Error
    end.

create_payment(#{ <<"id">> := PaymentId } = Payment, Context) ->
    case is_eligible_payment(Payment) of
        true ->
            case checkout_request(Payment, Context) of
                {ok, Request, IdempotencyKey} ->
                    Options = [
                        {content_type, <<"application/json">>},
                        {headers, [{<<"Idempotency-Key">>, IdempotencyKey}]},
                        {timeout, ?TIMEOUT}
                    ],
                    case api_json(post, <<"/v2/checkout_sessions">>, Request,
                                  ?SCOPE_CHECKOUT_CREATE, Options, Context) of
                        {ok, Response} ->
                            checkout_result(Payment, Request, Response, Context);
                        {error, Reason} = Error ->
                            log_api_error(PaymentId, <<"create">>, Reason, Context),
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, ineligible_payment}
    end.

checkout_request(Payment, Context) ->
    case settings(Context) of
        {ok, #{ merchant_token := MerchantToken, environment := Environment }} ->
            Currency = maps:get(<<"currency">>, Payment),
            Amount = amount_minor_units(maps:get(<<"amount">>, Payment), Currency),
            MerchantReference = maps:get(<<"payment_nr">>, Payment),
            IdempotencyKey = idempotency_key(MerchantReference),
            Request0 = #{
                <<"merchantToken">> => MerchantToken,
                <<"amount">> => Amount,
                <<"currency">> => Currency,
                <<"environment">> => Environment,
                <<"merchantReference">> => MerchantReference,
                <<"idempotencyKey">> => IdempotencyKey
            },
            {ok, Request0, IdempotencyKey};
        {error, _} = Error ->
            Error
    end.

checkout_result(#{ <<"id">> := PaymentId } = Payment, Request, Response, Context) ->
    case validate_checkout_response(Response, Request) of
        ok ->
            CheckoutSessionRef = maps:get(<<"checkoutSessionRef">>, Response),
            %% Sovergn confirms checkoutUrl as the ready URL. Hosted checkout
            %% remains on Sovergn's result page, so no merchant return URLs are
            %% sent. Embedded post_message completion is outside this module.
            CheckoutUrl = maps:get(<<"checkoutUrl">>, Response),
            Data = checkout_data(Response),
            _ = m_payment_log:log(
                PaymentId,
                <<"sovergn.checkout.created">>,
                #{
                    <<"psp_module">> => mod_payment_sovergn,
                    <<"psp_external_log_id">> => CheckoutSessionRef,
                    <<"description">> => <<"Created Sovergn checkout session">>,
                    <<"sovergn_checkout">> => Data
                },
                Context),
            {ok, #payment_psp_handler{
                psp_module = mod_payment_sovergn,
                psp_external_id = CheckoutSessionRef,
                psp_data = Data,
                redirect_uri = CheckoutUrl
            }};
        {error, Reason} = Error ->
            log_api_error(maps:get(<<"id">>, Payment), <<"validate">>, Reason, Context),
            Error
    end.

-spec validate_checkout_response(map(), map()) -> ok | {error, term()}.
validate_checkout_response(Response, Request) when is_map(Response), is_map(Request) ->
    RequiredMatches = [
        {<<"merchantToken">>, <<"merchantToken">>},
        {<<"merchantReference">>, <<"merchantReference">>},
        {<<"amount">>, <<"amount">>},
        {<<"currency">>, <<"currency">>},
        {<<"environment">>, <<"environment">>}
    ],
    IsMatch = lists:all(
        fun({ResponseKey, RequestKey}) ->
            maps:get(ResponseKey, Response, undefined) =:= maps:get(RequestKey, Request, undefined)
        end,
        RequiredMatches),
    CheckoutUrl = maps:get(<<"checkoutUrl">>, Response, undefined),
    CheckoutSessionRef = maps:get(<<"checkoutSessionRef">>, Response, undefined),
    IsReady = maps:get(<<"outcome">>, Response, undefined) =:= <<"checkout_ready">>
        andalso maps:get(<<"decision">>, Response, undefined) =:= <<"ALLOW">>
        andalso maps:get(<<"checkoutMode">>, Response, undefined) =:= <<"hosted">>
        andalso maps:get(<<"providerBlind">>, Response, undefined) =:= true
        andalso is_binary(CheckoutSessionRef)
        andalso CheckoutSessionRef =/= <<>>
        andalso lists:member(
            maps:get(<<"idempotencyStatus">>, Response, undefined),
            [<<"created">>, <<"replayed">>]),
    case IsMatch andalso IsReady andalso checkout_url_allowed(CheckoutUrl) of
        true -> ok;
        false -> {error, invalid_checkout_response}
    end;
validate_checkout_response(_Response, _Request) ->
    {error, invalid_checkout_response}.

checkout_url_allowed(CheckoutUrl) when is_binary(CheckoutUrl) ->
    Prefix = <<?CHECKOUT_ORIGIN/binary, ?CHECKOUT_PATH_PREFIX/binary>>,
    case binary:match(CheckoutUrl, Prefix) of
        {0, _} -> true;
        _ -> false
    end;
checkout_url_allowed(_) ->
    false.

checkout_data(Response) ->
    maps:with([
        <<"checkoutSessionRef">>,
        <<"checkoutUrl">>,
        <<"checkoutMode">>,
        <<"merchantReference">>,
        <<"merchantToken">>,
        <<"amount">>,
        <<"currency">>,
        <<"decision">>,
        <<"outcome">>,
        <<"providerBlind">>,
        <<"captureMode">>,
        <<"environment">>,
        <<"expiresAt">>,
        <<"idempotencyStatus">>
    ], Response).

-spec sync(binary(), z:context()) -> {ok, {binary(), atom()}} | {error, term()}.
sync(CheckoutSessionRef, Context) when is_binary(CheckoutSessionRef), CheckoutSessionRef =/= <<>> ->
    case {settings(Context), m_payment:get_by_psp(mod_payment_sovergn, CheckoutSessionRef, Context)} of
        {{ok, #{ merchant_token := MerchantToken }}, {ok, Payment}} ->
            Path = iolist_to_binary([
                <<"/v2/developer/merchants/">>, z_url:url_encode(MerchantToken),
                <<"/payment-status/checkout_sessions/">>, z_url:url_encode(CheckoutSessionRef)
            ]),
            case api_json(get, Path, undefined, ?SCOPE_PAYMENT_STATUS, [], Context) of
                {ok, StatusResponse} ->
                    apply_status_response(Payment, CheckoutSessionRef, StatusResponse, Context);
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end;
sync(_CheckoutSessionRef, _Context) ->
    {error, checkout_session_ref}.

apply_status_response(Payment, CheckoutSessionRef, StatusResponse, Context) ->
    case validate_status_response(Payment, CheckoutSessionRef, StatusResponse, Context) of
        ok ->
            case payment_sovergn_status:guess_api_status(StatusResponse) of
                {ok, Status} ->
                    PaymentId = maps:get(<<"id">>, Payment),
                    PaymentNr = maps:get(<<"payment_nr">>, Payment),
                    Date = status_datetime(StatusResponse),
                    _ = m_payment_log:log(
                        PaymentId,
                        <<"sovergn.status">>,
                        #{
                            <<"psp_module">> => mod_payment_sovergn,
                            <<"psp_external_log_id">> => CheckoutSessionRef,
                            <<"description">> => <<"Synchronized Sovergn payment status">>,
                            <<"sovergn_status">> => StatusResponse
                        },
                        Context),
                    case mod_payment:set_payment_status(PaymentId, Status, Date, Context) of
                        ok -> {ok, {PaymentNr, Status}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

validate_status_response(Payment, CheckoutSessionRef, StatusResponse, Context) when is_map(StatusResponse) ->
    CurrencyMatches = matches_required(
        <<"currency">>, maps:get(<<"currency">>, Payment), StatusResponse),
    AmountMatches = matches_required(
        <<"amount">>,
        amount_minor_units(maps:get(<<"amount">>, Payment), maps:get(<<"currency">>, Payment)),
        StatusResponse),
    ReferenceMatches = matches_required(
        <<"merchantReference">>, maps:get(<<"payment_nr">>, Payment), StatusResponse),
    SessionMatches = matches_required(
        <<"checkoutSessionRef">>, CheckoutSessionRef, StatusResponse),
    MerchantMatches = matches_required(
        <<"merchantToken">>, config_binary(merchant_token, Context), StatusResponse),
    case CurrencyMatches andalso AmountMatches andalso ReferenceMatches
        andalso SessionMatches andalso MerchantMatches
    of
        true -> ok;
        false -> {error, invalid_status_response}
    end;
validate_status_response(_Payment, _CheckoutSessionRef, _StatusResponse, _Context) ->
    {error, invalid_status_response}.

matches_required(Key, Expected, Map) ->
    maps:get(Key, Map, undefined) =:= Expected.

status_datetime(StatusResponse) ->
    Timestamp = first_defined([
        maps:get(<<"occurredAt">>, StatusResponse, undefined),
        maps:get(<<"updatedAt">>, StatusResponse, undefined),
        maps:get(<<"completedAt">>, StatusResponse, undefined)
    ]),
    case Timestamp of
        T when is_binary(T) ->
            case payment_sovergn_webhook:parse_timestamp(T) of
                {ok, Seconds} -> calendar:system_time_to_universal_time(Seconds, second);
                {error, _} -> calendar:universal_time()
            end;
        _ ->
            calendar:universal_time()
    end.

first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value;
first_defined([]) -> undefined.

api_json(Method, Path, Payload, Scope, ExtraOptions, Context) ->
    case access_token(Scope, Context) of
        {ok, AccessToken} ->
            Authorization = <<"Bearer ", AccessToken/binary>>,
            Options = [{authorization, Authorization}, {timeout, ?TIMEOUT} | ExtraOptions],
            Url = <<?API_ORIGIN/binary, Path/binary>>,
            case Method of
                get -> z_fetch:fetch_json(Url, Options, Context);
                post -> z_fetch:fetch_json(post, Url, Payload, Options, Context)
            end;
        {error, _} = Error ->
            Error
    end.

access_token(Scope, Context) ->
    case oauth_credentials(Context) of
        {ok, ClientId, ClientSecret} ->
            CredentialVersion = crypto:hash(sha256, ClientSecret),
            CacheKey = {?MODULE, access_token, Scope, ClientId, CredentialVersion},
            case z_depcache:get(CacheKey, Context) of
                {ok, Token} when is_binary(Token), Token =/= <<>> ->
                    {ok, Token};
                _ ->
                    fetch_access_token(
                        CacheKey, Scope, ClientId, ClientSecret, Context)
            end;
        {error, _} = Error ->
            Error
    end.

fetch_access_token(CacheKey, Scope, ClientId, ClientSecret, Context) ->
    Basic = base64:encode(<<ClientId/binary, $:, ClientSecret/binary>>),
    Authorization = <<"Basic ", Basic/binary>>,
    Payload = #{
        <<"grant_type">> => <<"client_credentials">>,
        <<"scope">> => Scope
    },
    Options = [
        {authorization, Authorization},
        {content_type, <<"application/x-www-form-urlencoded">>},
        {timeout, ?TIMEOUT}
    ],
    Url = <<?API_ORIGIN/binary, "/oauth/token">>,
    case z_fetch:fetch_json(post, Url, Payload, Options, Context) of
        {ok, #{
            <<"access_token">> := Token,
            <<"token_type">> := <<"Bearer">>,
            <<"expires_in">> := ExpiresIn,
            <<"scope">> := Scope
        }} when is_binary(Token), Token =/= <<>>, is_integer(ExpiresIn) ->
            MaxAge = max(1, ExpiresIn - 30),
            ok = z_depcache:set(CacheKey, Token, MaxAge, Context),
            {ok, Token};
        {ok, _} ->
            {error, oauth_response};
        {error, _} = Error ->
            Error
    end.

oauth_credentials(Context) ->
    ClientId = config_binary(oauth_client_id, Context),
    ClientSecret = config_binary(oauth_client_secret, Context),
    case {ClientId, ClientSecret} of
        {<<>>, _} -> {error, oauth_credentials};
        {_, <<>>} -> {error, oauth_credentials};
        _ -> {ok, ClientId, ClientSecret}
    end.

settings(Context) ->
    MerchantToken = config_binary(merchant_token, Context),
    Environment = config_binary(environment, Context),
    case {MerchantToken, Environment} of
        {<<>>, _} -> {error, merchant_token};
        {_, <<"test">>} -> {ok, #{merchant_token => MerchantToken, environment => Environment}};
        {_, <<"live">>} -> {ok, #{merchant_token => MerchantToken, environment => Environment}};
        _ -> {error, environment}
    end.

config_binary(Key, Context) ->
    z_convert:to_binary(m_config:get_value(mod_payment_sovergn, Key, Context)).

-spec is_eligible_payment(map()) -> boolean().
is_eligible_payment(Payment) when is_map(Payment) ->
    Currency = maps:get(<<"currency">>, Payment, undefined),
    Amount = maps:get(<<"amount">>, Payment, undefined),
    IsRecurring = z_convert:to_bool(maps:get(<<"is_recurring_start">>, Payment, false)),
    HasContact = has_valid_email(Payment) andalso has_name(Payment),
    IsReferencedPaymentLink = is_payment_link(Payment) andalso has_reference(Payment),
    lists:member(Currency, [<<"EUR">>, <<"USD">>])
        andalso is_number(Amount)
        andalso Amount > 0
        andalso not IsRecurring
        andalso (HasContact orelse IsReferencedPaymentLink);
is_eligible_payment(_) ->
    false.

has_valid_email(Payment) ->
    case maps:get(<<"email">>, Payment, undefined) of
        Email when is_binary(Email), Email =/= <<>> -> z_email_utils:is_email(Email);
        _ -> false
    end.

has_name(Payment) ->
    lists:any(
        fun(Key) -> not z_utils:is_empty(maps:get(Key, Payment, undefined)) end,
        [<<"name_first">>, <<"name_surname_prefix">>, <<"name_surname">>]).

is_payment_link(Payment) ->
    z_convert:to_bool(payment_property(<<"is_payment_link">>, Payment)).

has_reference(Payment) ->
    not z_utils:is_empty(payment_property(<<"reference">>, Payment)).

payment_property(Key, Payment) ->
    case maps:find(Key, Payment) of
        {ok, Value} -> Value;
        error ->
            Props = maps:get(<<"props">>, Payment, #{}),
            maps:get(Key, Props, undefined)
    end.

-spec amount_minor_units(number(), binary()) -> integer().
amount_minor_units(Amount, Currency) when Currency =:= <<"EUR">>; Currency =:= <<"USD">> ->
    round(Amount * 100).

-spec idempotency_key(binary()) -> binary().
idempotency_key(MerchantReference) when is_binary(MerchantReference) ->
    Digest = crypto:hash(sha256, <<"sovergn-checkout:", MerchantReference/binary>>),
    z_string:to_lower(z_utils:hex_encode(Digest)).

log_api_error(PaymentId, Operation, Reason, Context) ->
    ?LOG_ERROR(#{
        in => zotonic_mod_payment_sovergn,
        text => <<"Sovergn API operation failed">>,
        result => error,
        reason => Reason,
        operation => Operation,
        payment_id => PaymentId
    }),
    m_payment_log:log(
        PaymentId,
        <<"sovergn.error">>,
        #{
            <<"psp_module">> => mod_payment_sovergn,
            <<"description">> => <<"Sovergn API operation failed">>,
            <<"operation">> => Operation,
            <<"reason">> => z_convert:to_binary(io_lib:format("~p", [Reason]))
        },
        Context).
