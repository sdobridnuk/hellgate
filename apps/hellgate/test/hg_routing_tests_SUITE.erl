-module(hg_routing_tests_SUITE).

-include("hg_ct_domain.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("dmsl/include/dmsl_payment_processing_thrift.hrl").
-include_lib("dmsl/include/dmsl_payment_processing_errors_thrift.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([gathers_fail_rated_providers/1]).
-export([no_route_found_for_payment/1]).
-export([fail_rate_affects_routing/1]).

-type config()         :: hg_ct_helper:config().
-type test_case_name() :: hg_ct_helper:test_case_name().
-type group_name()     :: hg_ct_helper:group_name().
-type test_return()    :: _ | no_return().

-spec all() -> [test_case_name() | {group, group_name()}].
all() -> [no_route_found_for_payment, fail_rate_affects_routing].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() -> [].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    CowboySpec = hg_dummy_provider:get_http_cowboy_spec(),
    {Apps, _Ret} = hg_ct_helper:start_apps([
        lager, woody, scoper, dmt_client, hellgate, {cowboy, CowboySpec}
    ]),
    ok = hg_domain:insert(construct_domain_fixture()),
    [{apps, Apps} | C].

-spec end_per_suite(config()) -> _.
end_per_suite(_C) -> ok = hg_domain:cleanup().

-spec init_per_group(group_name(), config()) -> config().
init_per_group(_, C) -> C.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, _C) -> ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(fail_rate_affects_routing, C) ->
    Revision = hg_domain:head(),
    ok = hg_domain:upsert(fail_rate_affects_routing_fixture(Revision)),
    C;
init_per_testcase(_, C) -> C.

-spec end_per_testcase(test_case_name(), config()) -> config().
end_per_testcase(_Name, C) ->
    _ = case cfg(original_domain_revision, C) of
        Revision when is_integer(Revision) ->
            ok = hg_domain:reset(Revision);
        undefined ->
            ok
    end.

cfg(Key, C) ->
    hg_ct_helper:cfg(Key, C).

-spec gathers_fail_rated_providers(config()) -> test_return().
gathers_fail_rated_providers(_C) ->
    VS1 = #{
        category        => ?cat(1),
        currency        => ?cur(<<"RUB">>),
        cost            => ?cash(1000, <<"RUB">>),
        payment_tool    => {bank_card, #domain_BankCard{}},
        party_id        => <<"12345">>,
        risk_score      => low,
        flow            => instant
    },

    Revision = hg_domain:head(),
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [] = hg_routing:gathers_fail_rated_providers(PaymentInstitution, VS1, Revision),
    ok.

-spec no_route_found_for_payment(config()) -> test_return().
no_route_found_for_payment(_C) ->
    Revision = hg_domain:head(),
    VS1 = #{
        category        => ?cat(1),
        currency        => ?cur(<<"RUB">>),
        cost            => ?cash(1000, <<"RUB">>),
        payment_tool    => {bank_card, #domain_BankCard{}},
        party_id        => <<"12345">>,
        risk_score      => low,
        flow            => instant
    },

    ScoredProviders = [
        {#domain_ProviderRef{id = 1}, 0.0},
        {#domain_ProviderRef{id = 2}, 0.0},
        {#domain_ProviderRef{id = 3}, 0.0}
    ],

    {error, {no_route_found, #{
        varset := VS1,
        rejected_providers := [
            {?prv(3), {'PaymentsProvisionTerms', payment_tool}},
            {?prv(2), {'PaymentsProvisionTerms', category}},
            {?prv(1), {'PaymentsProvisionTerms', payment_tool}}
        ],
        rejected_terminals := []
    }}} = hg_routing:choose(payment, ScoredProviders, VS1, Revision),
    VS2 = VS1#{
        payment_tool => {payment_terminal, #domain_PaymentTerminal{terminal_type = euroset}}
    },
    {ok, #domain_PaymentRoute{
        provider = ?prv(3),
        terminal = ?trm(10)
    }} = hg_routing:choose(payment, ScoredProviders, VS2, Revision).

-spec fail_rate_affects_routing(config()) -> test_return().

fail_rate_affects_routing(_C) ->
    Revision = hg_domain:head(),

    VS = #{
        category        => ?cat(1),
        currency        => ?cur(<<"RUB">>),
        cost            => ?cash(1000, <<"RUB">>),
        payment_tool    => {payment_terminal, #domain_PaymentTerminal{terminal_type = euroset}},
        party_id        => <<"12345">>,
        risk_score      => low,
        flow            => instant
    },

    ScoredProviders0 = [
        {#domain_ProviderRef{id = 200}, 0.0},
        {#domain_ProviderRef{id = 201}, 1.0},
        {#domain_ProviderRef{id = 202}, 1.0}
    ],
    ScoredProviders1 = [
        {#domain_ProviderRef{id = 200}, 1.0},
        {#domain_ProviderRef{id = 201}, 0.0},
        {#domain_ProviderRef{id = 202}, 1.0}
    ],
    ScoredProviders2 = [
        {#domain_ProviderRef{id = 200}, 1.0},
        {#domain_ProviderRef{id = 201}, 1.0},
        {#domain_ProviderRef{id = 202}, 0.0}
    ],
    ScoredProviders3 = [
        {#domain_ProviderRef{id = 200}, 0.6},
        {#domain_ProviderRef{id = 201}, 0.7},
        {#domain_ProviderRef{id = 202}, 1.0}
    ],
    % ScoredProviders3 = [
    %     {#domain_ProviderRef{id = 200}, 0.5},
    %     {#domain_ProviderRef{id = 201}, 0.0},
    %     {#domain_ProviderRef{id = 202}, 1.0}
    % ],

    Result0 = hg_routing:choose(payment, ScoredProviders0, VS, Revision),
    Result1 = hg_routing:choose(payment, ScoredProviders1, VS, Revision),
    Result2 = hg_routing:choose(payment, ScoredProviders2, VS, Revision),
    Result3 = hg_routing:choose(payment, ScoredProviders3, VS, Revision),

    {ok, #domain_PaymentRoute{provider = ?prv(200)}} = Result0,
    {ok, #domain_PaymentRoute{provider = ?prv(201)}} = Result1,
    {ok, #domain_PaymentRoute{provider = ?prv(202)}} = Result2,
    {ok, #domain_PaymentRoute{provider = ?prv(200)}} = Result3,

    ok.

fail_rate_affects_routing_fixture(Revision) ->
    PaymentInstitution = hg_domain:get(Revision, {payment_institution, ?pinst(1)}),
    [
        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = PaymentInstitution#domain_PaymentInstitution{
                providers = {value, ?ordset([
                    ?prv(200),
                    ?prv(201),
                    ?prv(202)
                ])}
            }}
        },
        {terminal, #domain_TerminalObject{
            ref = ?trm(111),
            data = #domain_Terminal{
                name = <<"Payment Terminal Terminal">>,
                description = <<"Euroset">>,
                risk_coverage = low
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(222),
            data = #domain_Terminal{
                name = <<"Payment Terminal Terminal">>,
                description = <<"Euroset">>,
                risk_coverage = high
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(200),
            data = #domain_Provider{
                name = <<"Biba">>,
                description = <<"Payment terminal provider">>,
                terminal = {value, [?trm(111)]},
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"biba">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                payment_terms = #domain_PaymentsProvisionTerms{
                    currencies = {value, ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
                    categories = {value, ?ordset([
                        ?cat(1)
                    ])},
                    payment_methods = {value, ?ordset([
                        ?pmt(payment_terminal, euroset),
                        ?pmt(digital_wallet, qiwi)
                    ])},
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash(    1000, <<"RUB">>)},
                        {exclusive, ?cash(10000000, <<"RUB">>)}
                    )},
                    cash_flow = {value, [
                        ?cfpost(
                            {provider, settlement},
                            {merchant, settlement},
                            ?share(1, 1, operation_amount)
                        ),
                        ?cfpost(
                            {system, settlement},
                            {provider, settlement},
                            ?share(21, 1000, operation_amount)
                        )
                    ]}
                }
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(201),
            data = #domain_Provider{
                name = <<"Boba">>,
                description = <<"Payment terminal provider">>,
                terminal = {value, [?trm(111)]},
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"biba">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                payment_terms = #domain_PaymentsProvisionTerms{
                    currencies = {value, ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
                    categories = {value, ?ordset([
                        ?cat(1)
                    ])},
                    payment_methods = {value, ?ordset([
                        ?pmt(payment_terminal, euroset),
                        ?pmt(digital_wallet, qiwi)
                    ])},
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash(    1000, <<"RUB">>)},
                        {exclusive, ?cash(10000000, <<"RUB">>)}
                    )},
                    cash_flow = {value, [
                        ?cfpost(
                            {provider, settlement},
                            {merchant, settlement},
                            ?share(1, 1, operation_amount)
                        ),
                        ?cfpost(
                            {system, settlement},
                            {provider, settlement},
                            ?share(21, 1000, operation_amount)
                        )
                    ]}
                }
            }
        }},
        {provider, #domain_ProviderObject{
            ref = ?prv(202),
            data = #domain_Provider{
                name = <<"Buba">>,
                description = <<"Payment terminal provider">>,
                terminal = {value, [?trm(222)]},
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"buba">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                payment_terms = #domain_PaymentsProvisionTerms{
                    currencies = {value, ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
                    categories = {value, ?ordset([
                        ?cat(1)
                    ])},
                    payment_methods = {value, ?ordset([
                        ?pmt(payment_terminal, euroset),
                        ?pmt(digital_wallet, qiwi)
                    ])},
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash(    1000, <<"RUB">>)},
                        {exclusive, ?cash(10000000, <<"RUB">>)}
                    )},
                    cash_flow = {value, [
                        ?cfpost(
                            {provider, settlement},
                            {merchant, settlement},
                            ?share(1, 1, operation_amount)
                        ),
                        ?cfpost(
                            {system, settlement},
                            {provider, settlement},
                            ?share(21, 1000, operation_amount)
                        )
                    ]}
                }
            }
        }}
    ].

construct_domain_fixture() ->
    TestTermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies = {value, ?ordset([
                ?cur(<<"RUB">>)
            ])},
            categories = {value, ?ordset([
                ?cat(1)
            ])},
            payment_methods = {decisions, [
                #domain_PaymentMethodDecision{
                    if_   = ?partycond(<<"DEPRIVED ONE">>, undefined),
                    then_ = {value, ordsets:new()}
                },
                #domain_PaymentMethodDecision{
                    if_   = {constant, true},
                    then_ = {value, ?ordset([
                        ?pmt(bank_card, visa),
                        ?pmt(bank_card, mastercard),
                        ?pmt(bank_card, jcb),
                        ?pmt(payment_terminal, euroset),
                        ?pmt(digital_wallet, qiwi),
                        ?pmt(empty_cvv_bank_card, visa),
                        ?pmt(tokenized_bank_card, ?tkz_bank_card(visa, applepay))
                    ])}
                }
            ]},
            cash_limit = {decisions, [
                #domain_CashLimitDecision{
                    if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                    then_ = {value, ?cashrng(
                        {inclusive, ?cash(     10, <<"RUB">>)},
                        {exclusive, ?cash(420000000, <<"RUB">>)}
                    )}
                }
            ]},
            fees = {decisions, [
                #domain_CashFlowDecision{
                    if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                    then_ = {value, [
                        ?cfpost(
                            {merchant, settlement},
                            {system, settlement},
                            ?share(45, 1000, operation_amount)
                        )
                    ]}
                }
            ]},
            holds = #domain_PaymentHoldsServiceTerms{
                payment_methods = {value, ?ordset([
                    ?pmt(bank_card, visa),
                    ?pmt(bank_card, mastercard)
                ])},
                lifetime = {decisions, [
                    #domain_HoldLifetimeDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ = {value, #domain_HoldLifetime{seconds = 10}}
                    }
                ]}
            },
            refunds = #domain_PaymentRefundsServiceTerms{
                payment_methods = {value, ?ordset([
                    ?pmt(bank_card, visa),
                    ?pmt(bank_card, mastercard)
                ])},
                fees = {value, [
                    ?cfpost(
                        {merchant, settlement},
                        {system, settlement},
                        ?fixed(100, <<"RUB">>)
                    )
                ]},
                eligibility_time = {value, #'TimeSpan'{minutes = 1}},
                partial_refunds = #domain_PartialRefundsServiceTerms{
                    cash_limit = {decisions, [
                        #domain_CashLimitDecision{
                            if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                            then_ = {value, ?cashrng(
                                {inclusive, ?cash(      1000, <<"RUB">>)},
                                {exclusive, ?cash(1000000000, <<"RUB">>)}
                            )}
                        }
                    ]}

                }
            }
        },
        recurrent_paytools = #domain_RecurrentPaytoolsServiceTerms{
            payment_methods = {value, ordsets:from_list([
                ?pmt(bank_card, visa),
                ?pmt(bank_card, mastercard)
            ])}
        }
    },
    DefaultTermSet = #domain_TermSet{
        payments = #domain_PaymentsServiceTerms{
            currencies = {value, ?ordset([
                ?cur(<<"RUB">>),
                ?cur(<<"USD">>)
            ])},
            categories = {value, ?ordset([
                ?cat(2),
                ?cat(3),
                ?cat(4),
                ?cat(5),
                ?cat(6)
            ])},
            payment_methods = {value, ?ordset([
                ?pmt(bank_card, visa),
                ?pmt(bank_card, mastercard)
            ])},
            cash_limit = {decisions, [
                % проверяем, что условие никогда не отрабатывает
                #domain_CashLimitDecision {
                    if_ = {condition, {payment_tool, {bank_card, #domain_BankCardCondition{
                        definition = {empty_cvv_is, true}
                    }}}},
                    then_ = {value,
                        ?cashrng(
                            {inclusive, ?cash(0, <<"RUB">>)},
                            {inclusive, ?cash(0, <<"RUB">>)}
                        )
                    }
                },
                #domain_CashLimitDecision{
                    if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                    then_ = {value, ?cashrng(
                        {inclusive, ?cash(     10, <<"RUB">>)},
                        {exclusive, ?cash(  4200000, <<"RUB">>)}
                    )}
                },
                #domain_CashLimitDecision{
                    if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                    then_ = {value, ?cashrng(
                        {inclusive, ?cash(      200, <<"USD">>)},
                        {exclusive, ?cash(   313370, <<"USD">>)}
                    )}
                }
            ]},
            fees = {decisions, [
                #domain_CashFlowDecision{
                    if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                    then_ = {value, [
                        ?cfpost(
                            {merchant, settlement},
                            {system, settlement},
                            ?share(45, 1000, operation_amount)
                        )
                    ]}
                },
                #domain_CashFlowDecision{
                    if_ = {condition, {currency_is, ?cur(<<"USD">>)}},
                    then_ = {value, [
                        ?cfpost(
                            {merchant, settlement},
                            {system, settlement},
                            ?share(65, 1000, operation_amount)
                        )
                    ]}
                }
            ]},
            holds = #domain_PaymentHoldsServiceTerms{
                payment_methods = {value, ?ordset([
                    ?pmt(bank_card, visa),
                    ?pmt(bank_card, mastercard)
                ])},
                lifetime = {decisions, [
                    #domain_HoldLifetimeDecision{
                        if_ = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ = {value, #domain_HoldLifetime{seconds = 3}}
                    }
                ]}
            },
            refunds = #domain_PaymentRefundsServiceTerms{
                payment_methods = {value, ?ordset([
                    ?pmt(bank_card, visa),
                    ?pmt(bank_card, mastercard)
                ])},
                fees = {value, [
                ]},
                eligibility_time = {value, #'TimeSpan'{minutes = 1}},
                partial_refunds = #domain_PartialRefundsServiceTerms{
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash( 1000, <<"RUB">>)},
                        {exclusive, ?cash(40000, <<"RUB">>)}
                    )}
                }
            }
        }
    },
    [
        hg_ct_fixture:construct_currency(?cur(<<"RUB">>)),
        hg_ct_fixture:construct_currency(?cur(<<"USD">>)),

        hg_ct_fixture:construct_category(?cat(1), <<"Test category">>, test),
        hg_ct_fixture:construct_category(?cat(2), <<"Generic Store">>, live),
        hg_ct_fixture:construct_category(?cat(3), <<"Guns & Booze">>, live),
        hg_ct_fixture:construct_category(?cat(4), <<"Offliner">>, live),
        hg_ct_fixture:construct_category(?cat(5), <<"Timeouter">>, live),
        hg_ct_fixture:construct_category(?cat(6), <<"MachineFailer">>, live),

        hg_ct_fixture:construct_payment_method(?pmt(bank_card, visa)),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, mastercard)),
        hg_ct_fixture:construct_payment_method(?pmt(bank_card, jcb)),
        hg_ct_fixture:construct_payment_method(?pmt(payment_terminal, euroset)),
        hg_ct_fixture:construct_payment_method(?pmt(digital_wallet, qiwi)),
        hg_ct_fixture:construct_payment_method(?pmt(empty_cvv_bank_card, visa)),
        hg_ct_fixture:construct_payment_method(?pmt(tokenized_bank_card, ?tkz_bank_card(visa, applepay))),

        hg_ct_fixture:construct_proxy(?prx(1), <<"Dummy proxy">>),
        hg_ct_fixture:construct_proxy(?prx(2), <<"Inspector proxy">>),

        hg_ct_fixture:construct_inspector(?insp(1), <<"Rejector">>, ?prx(2), #{<<"risk_score">> => <<"low">>}),
        hg_ct_fixture:construct_inspector(?insp(2), <<"Skipper">>, ?prx(2), #{<<"risk_score">> => <<"high">>}),
        hg_ct_fixture:construct_inspector(?insp(3), <<"Fatalist">>, ?prx(2), #{<<"risk_score">> => <<"fatal">>}),
        hg_ct_fixture:construct_inspector(?insp(4), <<"Offliner">>, ?prx(2),
            #{<<"link_state">> => <<"unexpected_failure">>}, low),
        hg_ct_fixture:construct_inspector(?insp(5), <<"Offliner">>, ?prx(2),
            #{<<"link_state">> => <<"timeout">>}, low),
        hg_ct_fixture:construct_inspector(?insp(6), <<"Offliner">>, ?prx(2),
            #{<<"link_state">> => <<"unexpected_failure">>}),

        hg_ct_fixture:construct_contract_template(?tmpl(1), ?trms(1)),
        hg_ct_fixture:construct_contract_template(?tmpl(2), ?trms(2)),
        hg_ct_fixture:construct_contract_template(?tmpl(3), ?trms(3)),

        hg_ct_fixture:construct_system_account_set(?sas(1)),
        hg_ct_fixture:construct_system_account_set(?sas(2)),
        hg_ct_fixture:construct_external_account_set(?eas(1)),
        hg_ct_fixture:construct_external_account_set(?eas(2), <<"Assist">>, ?cur(<<"RUB">>)),

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(1),
            data = #domain_PaymentInstitution{
                name = <<"Test Inc.">>,
                system_account_set = {value, ?sas(1)},
                default_contract_template = {value, ?tmpl(1)},
                providers = {value, ?ordset([
                    ?prv(1),
                    ?prv(2),
                    ?prv(3)
                ])},

                % TODO do we realy need this decision hell here?
                inspector = {decisions, [
                    #domain_InspectorDecision{
                        if_   = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ = {decisions, [
                            #domain_InspectorDecision{
                                if_ = {condition, {category_is, ?cat(3)}},
                                then_ = {value, ?insp(2)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {category_is, ?cat(4)}},
                                then_ = {value, ?insp(4)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {cost_in, ?cashrng(
                                    {inclusive, ?cash(        0, <<"RUB">>)},
                                    {exclusive, ?cash(   500000, <<"RUB">>)}
                                )}},
                                then_ = {value, ?insp(1)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {cost_in, ?cashrng(
                                    {inclusive, ?cash(   500000, <<"RUB">>)},
                                    {exclusive, ?cash(100000000, <<"RUB">>)}
                                )}},
                                then_ = {value, ?insp(2)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {cost_in, ?cashrng(
                                    {inclusive, ?cash( 100000000, <<"RUB">>)},
                                    {exclusive, ?cash(1000000000, <<"RUB">>)}
                                )}},
                                then_ = {value, ?insp(3)}
                            }
                        ]}
                    }
                ]},
                residences = [],
                realm = test
            }
        }},

        {payment_institution, #domain_PaymentInstitutionObject{
            ref = ?pinst(2),
            data = #domain_PaymentInstitution{
                name = <<"Chetky Payments Inc.">>,
                system_account_set = {value, ?sas(2)},
                default_contract_template = {value, ?tmpl(2)},
                providers = {value, ?ordset([
                    ?prv(1),
                    ?prv(2),
                    ?prv(3)
                ])},
                inspector = {decisions, [
                    #domain_InspectorDecision{
                        if_   = {condition, {currency_is, ?cur(<<"RUB">>)}},
                        then_ = {decisions, [
                            #domain_InspectorDecision{
                                if_ = {condition, {category_is, ?cat(3)}},
                                then_ = {value, ?insp(2)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {category_is, ?cat(4)}},
                                then_ = {value, ?insp(4)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {category_is, ?cat(5)}},
                                then_ = {value, ?insp(5)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {category_is, ?cat(6)}},
                                then_ = {value, ?insp(6)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {cost_in, ?cashrng(
                                    {inclusive, ?cash(        0, <<"RUB">>)},
                                    {exclusive, ?cash(   500000, <<"RUB">>)}
                                )}},
                                then_ = {value, ?insp(1)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {cost_in, ?cashrng(
                                    {inclusive, ?cash(   500000, <<"RUB">>)},
                                    {exclusive, ?cash(100000000, <<"RUB">>)}
                                )}},
                                then_ = {value, ?insp(2)}
                            },
                            #domain_InspectorDecision{
                                if_ = {condition, {cost_in, ?cashrng(
                                    {inclusive, ?cash( 100000000, <<"RUB">>)},
                                    {exclusive, ?cash(1000000000, <<"RUB">>)}
                                )}},
                                then_ = {value, ?insp(3)}
                            }
                        ]}
                    }
                ]},
                residences = [],
                realm = live
            }
        }},

        {globals, #domain_GlobalsObject{
            ref = #domain_GlobalsRef{},
            data = #domain_Globals{
                external_account_set = {decisions, [
                    #domain_ExternalAccountSetDecision{
                        if_ = {condition, {party, #domain_PartyCondition{
                            id = <<"LGBT">>
                        }}},
                        then_ = {value, ?eas(2)}
                    },
                    #domain_ExternalAccountSetDecision{
                        if_ = {constant, true},
                        then_ = {value, ?eas(1)}
                    }
                ]},
                payment_institutions = ?ordset([?pinst(1), ?pinst(2)])
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(1),
            data = #domain_TermSetHierarchy{
                term_sets = [#domain_TimedTermSet{
                    action_time = #'TimestampInterval'{},
                    terms = TestTermSet
                }]
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(2),
            data = #domain_TermSetHierarchy{
                term_sets = [#domain_TimedTermSet{
                    action_time = #'TimestampInterval'{},
                    terms = DefaultTermSet
                }]
            }
        }},
        {term_set_hierarchy, #domain_TermSetHierarchyObject{
            ref = ?trms(3),
            data = #domain_TermSetHierarchy{
                parent_terms = ?trms(1),
                term_sets = []
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(1),
            data = #domain_Provider{
                name = <<"Brovider">>,
                description = <<"A provider but bro">>,
                terminal = {value, ?ordset([
                    ?trm(1)
                ])},
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"brovider">>
                    }
                },
                abs_account = <<"1234567890">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                payment_terms = #domain_PaymentsProvisionTerms{
                    currencies = {value, ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
                    categories = {value, ?ordset([
                        ?cat(1)
                    ])},
                    payment_methods = {value, ?ordset([
                        ?pmt(bank_card, visa),
                        ?pmt(bank_card, mastercard),
                        ?pmt(bank_card, jcb),
                        ?pmt(empty_cvv_bank_card, visa),
                        ?pmt(tokenized_bank_card, ?tkz_bank_card(visa, applepay))
                    ])},
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash(      1000, <<"RUB">>)},
                        {exclusive, ?cash(1000000000, <<"RUB">>)}
                    )},
                    cash_flow = {decisions, [
                        #domain_CashFlowDecision{
                            if_   = {condition, {payment_tool, {bank_card, #domain_BankCardCondition{
                                definition = {payment_system_is, visa}
                            }}}},
                            then_ = {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(18, 1000, operation_amount)
                                )
                            ]}
                        },
                        #domain_CashFlowDecision{
                            if_   = {condition, {payment_tool, {bank_card, #domain_BankCardCondition{
                                definition = {payment_system_is, mastercard}
                            }}}},
                            then_ = {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(19, 1000, operation_amount)
                                )
                            ]}
                        },
                        #domain_CashFlowDecision{
                            if_   = {condition, {payment_tool, {bank_card, #domain_BankCardCondition{
                                definition = {payment_system_is, jcb}
                            }}}},
                            then_ = {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(20, 1000, operation_amount)
                                )
                            ]}
                        },
                        #domain_CashFlowDecision{
                            if_   = {condition, {payment_tool, {bank_card, #domain_BankCardCondition{
                                definition = {payment_system, #domain_PaymentSystemCondition{
                                    payment_system_is = visa,
                                    token_provider_is = applepay
                                }}
                            }}}},
                            then_ = {value, [
                                ?cfpost(
                                    {provider, settlement},
                                    {merchant, settlement},
                                    ?share(1, 1, operation_amount)
                                ),
                                ?cfpost(
                                    {system, settlement},
                                    {provider, settlement},
                                    ?share(20, 1000, operation_amount)
                                )
                            ]}
                        }
                    ]},
                    holds = #domain_PaymentHoldsProvisionTerms{
                        lifetime = {decisions, [
                            #domain_HoldLifetimeDecision{
                                if_   = {condition, {payment_tool, {bank_card, #domain_BankCardCondition{
                                    definition = {payment_system_is, visa}
                                }}}},
                                then_ = {value, ?hold_lifetime(12)}
                            }
                        ]}
                    },
                    refunds = #domain_PaymentRefundsProvisionTerms{
                        cash_flow = {value, [
                            ?cfpost(
                                {merchant, settlement},
                                {provider, settlement},
                                ?share(1, 1, operation_amount)
                            )
                        ]},
                        partial_refunds = #domain_PartialRefundsProvisionTerms{
                            cash_limit = {value, ?cashrng(
                                {inclusive, ?cash(        10, <<"RUB">>)},
                                {exclusive, ?cash(1000000000, <<"RUB">>)}
                            )}
                        }
                    }
                },
                recurrent_paytool_terms = #domain_RecurrentPaytoolsProvisionTerms{
                    categories = {value, ?ordset([?cat(1)])},
                    payment_methods = {value, ?ordset([
                        ?pmt(bank_card, visa),
                        ?pmt(bank_card, mastercard)
                    ])},
                    cash_value = {value, ?cash(1000, <<"RUB">>)}
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(1),
            data = #domain_Terminal{
                name = <<"Brominal 1">>,
                description = <<"Brominal 1">>,
                risk_coverage = high
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(2),
            data = #domain_Provider{
                name = <<"Drovider">>,
                description = <<"I'm out of ideas of what to write here">>,
                terminal = {value, [?trm(6), ?trm(7)]},
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"drovider">>
                    }
                },
                abs_account = <<"1234567890">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                payment_terms = #domain_PaymentsProvisionTerms{
                    currencies = {value, ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
                    categories = {value, ?ordset([
                        ?cat(2),
                        ?cat(4),
                        ?cat(5),
                        ?cat(6)
                    ])},
                    payment_methods = {value, ?ordset([
                        ?pmt(bank_card, visa),
                        ?pmt(bank_card, mastercard)
                    ])},
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash(    1000, <<"RUB">>)},
                        {exclusive, ?cash(10000000, <<"RUB">>)}
                    )},
                    cash_flow = {value, [
                        ?cfpost(
                            {provider, settlement},
                            {merchant, settlement},
                            ?share(1, 1, operation_amount)
                        ),
                        ?cfpost(
                            {system, settlement},
                            {provider, settlement},
                            ?share(16, 1000, operation_amount)
                        )
                    ]},
                    refunds = #domain_PaymentRefundsProvisionTerms{
                        cash_flow = {value, [
                            ?cfpost(
                                {merchant, settlement},
                                {provider, settlement},
                                ?share(1, 1, operation_amount)
                            )
                        ]},
                        partial_refunds = #domain_PartialRefundsProvisionTerms{
                            cash_limit = {value, ?cashrng(
                                {inclusive, ?cash(        10, <<"RUB">>)},
                                {exclusive, ?cash(1000000000, <<"RUB">>)}
                            )}
                        }
                    }
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(6),
            data = #domain_Terminal{
                name = <<"Drominal 1">>,
                description = <<"Drominal 1">>,
                risk_coverage = low,
                terms = #domain_PaymentsProvisionTerms{
                    currencies = {value, ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
                    categories = {value, ?ordset([
                        ?cat(2)
                    ])},
                    payment_methods = {value, ?ordset([
                        ?pmt(bank_card, visa)
                    ])},
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash(    1000, <<"RUB">>)},
                        {exclusive, ?cash( 5000000, <<"RUB">>)}
                    )},
                    cash_flow = {value, [
                        ?cfpost(
                            {provider, settlement},
                            {merchant, settlement},
                            ?share(1, 1, operation_amount)
                        ),
                        ?cfpost(
                            {system, settlement},
                            {provider, settlement},
                            ?share(16, 1000, operation_amount)
                        ),
                        ?cfpost(
                            {system, settlement},
                            {external, outcome},
                            ?fixed(20, <<"RUB">>),
                            <<"Assist fee">>
                        )
                    ]}
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(7),
            data = #domain_Terminal{
                name = <<"Terminal 7">>,
                description = <<"Terminal 7">>,
                risk_coverage = high
            }
        }},

        {provider, #domain_ProviderObject{
            ref = ?prv(3),
            data = #domain_Provider{
                name = <<"Crovider">>,
                description = <<"Payment terminal provider">>,
                terminal = {value, [?trm(10)]},
                proxy = #domain_Proxy{
                    ref = ?prx(1),
                    additional = #{
                        <<"override">> => <<"crovider">>
                    }
                },
                abs_account = <<"0987654321">>,
                accounts = hg_ct_fixture:construct_provider_account_set([?cur(<<"RUB">>)]),
                payment_terms = #domain_PaymentsProvisionTerms{
                    currencies = {value, ?ordset([
                        ?cur(<<"RUB">>)
                    ])},
                    categories = {value, ?ordset([
                        ?cat(1)
                    ])},
                    payment_methods = {value, ?ordset([
                        ?pmt(payment_terminal, euroset),
                        ?pmt(digital_wallet, qiwi)
                    ])},
                    cash_limit = {value, ?cashrng(
                        {inclusive, ?cash(    1000, <<"RUB">>)},
                        {exclusive, ?cash(10000000, <<"RUB">>)}
                    )},
                    cash_flow = {value, [
                        ?cfpost(
                            {provider, settlement},
                            {merchant, settlement},
                            ?share(1, 1, operation_amount)
                        ),
                        ?cfpost(
                            {system, settlement},
                            {provider, settlement},
                            ?share(21, 1000, operation_amount)
                        )
                    ]}
                }
            }
        }},
        {terminal, #domain_TerminalObject{
            ref = ?trm(10),
            data = #domain_Terminal{
                name = <<"Payment Terminal Terminal">>,
                description = <<"Euroset">>,
                risk_coverage = low
            }
        }}

    ].
