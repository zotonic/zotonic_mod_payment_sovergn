%% @copyright 2026
%% @doc Payment PSP module for Sovergn hosted checkout.
%%
%% The webhook URL is /sovergn/webhook. Only anonymous correlation values are
%% sent to Sovergn; payer names, email addresses, and business references stay
%% in Zotonic.
%% @end

%% Copyright 2026
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

-module(mod_payment_sovergn).
-moduledoc(#{
    zotonic_keywords => [
        "reference", "backend_developer", "site_administrator", "module",
        "payments", "configuration", "api_and_integration", "privacy"
    ]
}).
-moduledoc("
Provide experimental Sovergn hosted checkout for anonymous payments.

Enable this module together with `mod_payment` and select it with
`#payment_request{preferred_psp_module = mod_payment_sovergn}`. Only anonymous
correlation values are sent to Sovergn; payer names, email addresses and business
references remain in Zotonic.

Configure these site settings under **System → Payment configuration**, requiring
`use.mod_admin_config`:

- `environment`: `test` (default) or `live`.
- `merchant_token`: merchant credential.
- `oauth_client_id` and `oauth_client_secret`: OAuth credentials.
- `webhook_signing_secret`: HMAC secret, separate from the OAuth client secret.

All credentials must belong to the selected environment. The module logs missing
or invalid configuration on initialization. Webhooks at `/sovergn/webhook` verify
the signed body, timestamp and event identity, then match an existing payment
before updating its status. Status polling remains restricted to known payments;
this experimental adapter does not discover or import arbitrary account payments.
").


-mod_title("Payments using Sovergn").
-mod_description("Payments using the Sovergn hosted checkout").
-mod_author("Driebit").
-mod_depends([ mod_payment ]).
-mod_config([
    #{
        key => environment,
        type => binary,
        default => <<"test">>,
        options => [<<"test">>, <<"live">>],
        input => radio,
        description => "Sovergn environment: test or live; must match the OAuth client and webhook signing secret."
    },
    #{
        key => merchant_token,
        is_secret => true,
        type => binary,
        default => <<>>,
        description => "Sovergn merchant token."
    },
    #{
        key => oauth_client_id,
        type => binary,
        default => <<>>,
        description => "Sovergn OAuth 2.0 client id."
    },
    #{
        key => oauth_client_secret,
        is_secret => true,
        type => binary,
        default => <<>>,
        description => "Sovergn OAuth client secret, shown only once when created or rotated."
    },
    #{
        key => webhook_signing_secret,
        is_secret => true,
        type => binary,
        default => <<>>,
        description => "Sovergn webhook HMAC signing secret; separate from the OAuth client secret."
    }
]).

-export([
    init/1,
    observe_payment_psp_request/2,
    observe_payment_psp_view_url/2,
    observe_payment_psp_status_sync/2
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("zotonic_mod_payment/include/payment.hrl").

init(Context) ->
    lists:foreach(
        fun({Key, Default}) ->
            case m_config:get_value(?MODULE, Key, Context) of
                undefined -> m_config:set_value(?MODULE, Key, Default, Context);
                _ -> ok
            end
        end,
        [
            {environment, <<"test">>},
            {merchant_token, <<>>},
            {oauth_client_id, <<>>},
            {oauth_client_secret, <<>>},
            {webhook_signing_secret, <<>>}
        ]),
    log_config_status(Context).

log_config_status(Context) ->
    Missing = lists:filter(
        fun(Key) ->
            z_string:trim(z_convert:to_binary(
                m_config:get_value(?MODULE, Key, Context))) =:= <<>>
        end,
        [merchant_token, oauth_client_id, oauth_client_secret, webhook_signing_secret]),
    Environment = z_convert:to_binary(
        m_config:get_value(?MODULE, environment, Context)),
    Invalid = case lists:member(Environment, [<<"test">>, <<"live">>]) of
        true -> Missing;
        false -> [environment | Missing]
    end,
    case Invalid of
        [] ->
            ok;
        _ ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_sovergn,
                text => <<"Sovergn payment configuration is incomplete">>,
                result => error,
                reason => incomplete_config,
                missing_or_invalid => Invalid
            }),
            ok
    end.

%% @doc Handle non-recurring EUR and USD payments when no other PSP was selected.
observe_payment_psp_request(#payment_psp_request{
        payment_id = PaymentId,
        currency = Currency,
        is_recurring_start = false,
        preferred_psp_module = PreferredPspModule
    }, Context)
    when (Currency =:= <<"EUR">> orelse Currency =:= <<"USD">>)
     andalso (PreferredPspModule =:= undefined orelse PreferredPspModule =:= ?MODULE) ->
    payment_sovergn_api:create(PaymentId, Context);
observe_payment_psp_request(#payment_psp_request{}, _Context) ->
    undefined.

observe_payment_psp_view_url(#payment_psp_view_url{
        psp_module = ?MODULE,
        psp_data = #{ <<"checkoutUrl">> := CheckoutUrl }
    }, _Context) ->
    {ok, CheckoutUrl};
observe_payment_psp_view_url(#payment_psp_view_url{}, _Context) ->
    undefined.

observe_payment_psp_status_sync(#payment_psp_status_sync{
        payment_id = PaymentId,
        psp_module = ?MODULE,
        psp_external_id = CheckoutSessionRef
    }, Context) ->
    case payment_sovergn_api:sync(CheckoutSessionRef, Context) of
        {ok, _} ->
            ok;
        {error, Reason} = Error ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_sovergn,
                text => <<"Could not synchronize Sovergn payment status">>,
                result => error,
                reason => Reason,
                payment_id => PaymentId,
                checkout_session_ref => CheckoutSessionRef
            }),
            Error
    end;
observe_payment_psp_status_sync(#payment_psp_status_sync{}, _Context) ->
    undefined.
