%% @copyright 2026
%% @doc Sovergn webhook signature verification and timestamp parsing.
%% @end

-module(payment_sovergn_webhook).

-export([
    verify/7,
    parse_timestamp/1
]).

-define(SIGNATURE_VERSION, <<"aop-hmac-sha256-v1">>).
-define(TIMESTAMP_TOLERANCE, 300).

-spec verify(binary() | undefined, binary() | undefined, binary() | undefined,
             binary() | undefined, binary(), binary() | undefined, integer()) ->
    ok | {error, term()}.
verify(?SIGNATURE_VERSION, EventId, Timestamp, Signature, Body, Secret, Now)
    when is_binary(EventId), EventId =/= <<>>,
         is_binary(Timestamp), Timestamp =/= <<>>,
         is_binary(Signature), Signature =/= <<>>,
         is_binary(Body),
         is_binary(Secret), Secret =/= <<>>,
         is_integer(Now) ->
    case parse_timestamp(Timestamp) of
        {ok, EventTime} when abs(Now - EventTime) =< ?TIMESTAMP_TOLERANCE ->
            Signed = <<Timestamp/binary, $., EventId/binary, $., Body/binary>>,
            Mac = crypto:mac(hmac, sha256, Secret, Signed),
            Expected = z_string:to_lower(z_utils:hex_encode(Mac)),
            case is_signature(Signature)
                andalso m_identity:is_equal(Signature, Expected)
            of
                true -> ok;
                false -> {error, invalid_signature}
            end;
        {ok, _} ->
            {error, stale_timestamp};
        {error, _} = Error ->
            Error
    end;
verify(Version, _EventId, _Timestamp, _Signature, _Body, _Secret, _Now)
    when Version =/= ?SIGNATURE_VERSION ->
    {error, signature_version};
verify(_Version, _EventId, _Timestamp, _Signature, _Body, _Secret, _Now) ->
    {error, signature_headers}.

-spec parse_timestamp(binary()) -> {ok, integer()} | {error, timestamp}.
parse_timestamp(Timestamp) when is_binary(Timestamp) ->
    case re:run(
        Timestamp,
        <<"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$">>,
        [{capture, none}])
    of
        match ->
            try
                {ok, calendar:rfc3339_to_system_time(
                    binary_to_list(Timestamp),
                    [{unit, second}])}
            catch
                error:_ -> {error, timestamp}
            end;
        nomatch ->
            {error, timestamp}
    end.

is_signature(Signature) ->
    re:run(Signature, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match.
