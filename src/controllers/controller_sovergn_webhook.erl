%% @copyright 2026
%% @doc Verify and process Sovergn webhook events.
%% @end

-module(controller_sovergn_webhook).

-export([
    allowed_methods/1,
    is_authorized/1,
    process/4
]).

-include_lib("kernel/include/logger.hrl").

allowed_methods(Context) ->
    {[ <<"POST">> ], Context}.

is_authorized(Context) ->
    {Body, Context1} = cowmachine_req:req_body(Context),
    EventId = z_context:get_req_header(<<"aop-webhook-event-id">>, Context1),
    Version = z_context:get_req_header(<<"aop-webhook-signature-version">>, Context1),
    Timestamp = z_context:get_req_header(<<"aop-webhook-timestamp">>, Context1),
    Signature = z_context:get_req_header(<<"aop-webhook-signature">>, Context1),
    Secret = z_convert:to_binary(m_config:get_value(mod_payment_sovergn, webhook_signing_secret, Context1)),
    case payment_sovergn_webhook:verify(Version, EventId, Timestamp, Signature, Body, Secret, z_datetime:timestamp()) of
        ok ->
            Context2 = z_context:set(sovergn_webhook_body, Body, Context1),
            {true, z_context:set(sovergn_webhook_event_id, EventId, Context2)};
        {error, Reason} ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_sovergn,
                text => <<"Rejected Sovergn webhook">>,
                result => error,
                reason => Reason,
                event_id => EventId
            }),
            {<<"Sovergn-Webhook-Signature">>, Context1}
    end.

process(<<"POST">>, _AcceptedCT, _ProvidedCT, Context) ->
    Body = z_context:get(sovergn_webhook_body, Context),
    try z_json:decode(Body) of
        Payload when is_map(Payload) ->
            case handle(Payload, Context) of
                ok -> {true, Context};
                {error, payload} -> {{halt, 400}, Context};
                {error, _} -> {{halt, 500}, Context}
            end
    catch
        error:badarg:Stack ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_sovergn,
                text => <<"Invalid JSON in Sovergn webhook">>,
                result => error,
                reason => json,
                stack => Stack
            }),
            {{halt, 400}, Context}
    end.

handle(#{
        <<"event_id">> := EventId,
        <<"event_type">> := EventType,
        <<"occurred_at">> := OccurredAt,
        <<"merchantReference">> := MerchantReference,
        <<"amount">> := Amount,
        <<"currency">> := Currency,
        <<"status">> := SovergnStatus
    }, Context) when is_binary(EventId), is_binary(MerchantReference) ->
    case EventId =:= z_context:get(sovergn_webhook_event_id, Context) of
        true ->
            handle_payment(
                MerchantReference, EventId, EventType, OccurredAt,
                Amount, Currency, SovergnStatus, Context);
        false ->
            {error, payload}
    end;
handle(_Payload, _Context) ->
    {error, payload}.

handle_payment(MerchantReference, EventId, EventType, OccurredAt,
               Amount, Currency, SovergnStatus, Context) ->
    case m_payment:get(MerchantReference, Context) of
        {ok, Payment} ->
            case webhook_matches_payment(EventType, Payment, Amount, Currency) of
                true ->
                    case is_duplicate(EventId, Context) of
                        true -> ok;
                        false ->
                            Action = payment_sovergn_status:webhook_status(
                                EventType, SovergnStatus),
                            case apply_action(Action, Payment, OccurredAt, Context) of
                                ok -> log_event(Payment, EventId, EventType, OccurredAt,
                                                Amount, Currency, SovergnStatus, Context);
                                {error, _} = Error -> Error
                            end
                    end;
                false ->
                    {error, payment_mismatch}
            end;
        {error, _} = Error ->
            Error
    end.

webhook_matches_payment(<<"settlement.paid">>, Payment, _Amount, Currency) ->
    Currency =:= maps:get(<<"currency">>, Payment, undefined);
webhook_matches_payment(_EventType, Payment, Amount, Currency) ->
    PaymentCurrency = maps:get(<<"currency">>, Payment, undefined),
    PaymentAmount = maps:get(<<"amount">>, Payment, undefined),
    Currency =:= PaymentCurrency
        andalso is_number(Amount)
        andalso is_number(PaymentAmount)
        andalso Amount =:= payment_sovergn_api:amount_minor_units(PaymentAmount, PaymentCurrency).

apply_action({set, Status}, Payment, OccurredAt, Context) ->
    Date = occurred_at(OccurredAt),
    mod_payment:set_payment_status(maps:get(<<"id">>, Payment), Status, Date, Context);
apply_action(sync, #{ <<"psp_external_id">> := CheckoutSessionRef }, _OccurredAt, Context)
    when is_binary(CheckoutSessionRef), CheckoutSessionRef =/= <<>> ->
    case payment_sovergn_api:sync(CheckoutSessionRef, Context) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end;
apply_action(sync, _Payment, _OccurredAt, _Context) ->
    {error, checkout_session_ref};
apply_action(ignore, _Payment, _OccurredAt, _Context) ->
    ok;
apply_action({error, _} = Error, _Payment, _OccurredAt, _Context) ->
    Error.

occurred_at(Timestamp) when is_binary(Timestamp) ->
    case payment_sovergn_webhook:parse_timestamp(Timestamp) of
        {ok, Seconds} -> calendar:system_time_to_universal_time(Seconds, second);
        {error, _} -> calendar:universal_time()
    end;
occurred_at(_) ->
    calendar:universal_time().

is_duplicate(EventId, Context) ->
    case z_db:q1(
        "select 1 from payment_log where psp_module = $1 and psp_external_log_id = $2 limit 1",
        [mod_payment_sovergn, EventId],
        Context)
    of
        1 -> true;
        _ -> false
    end.

log_event(#{ <<"id">> := PaymentId }, EventId, EventType, OccurredAt,
          Amount, Currency, SovergnStatus, Context) ->
    case m_payment_log:log(
        PaymentId,
        <<"sovergn.webhook">>,
        #{
            <<"psp_module">> => mod_payment_sovergn,
            <<"psp_external_log_id">> => EventId,
            <<"description">> => <<"Processed Sovergn webhook">>,
            <<"event_type">> => EventType,
            <<"occurred_at">> => OccurredAt,
            <<"amount">> => Amount,
            <<"currency">> => Currency,
            <<"sovergn_status">> => SovergnStatus
        },
        Context)
    of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.
