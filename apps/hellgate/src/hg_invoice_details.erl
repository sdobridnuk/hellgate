-module(hg_invoice_details).
-include_lib("dmsl/include/dmsl_domain_thrift.hrl").

%% Msgpack marshalling callbacks

-behaviour(hg_msgpack_marshalling).

-export([marshal/2]).
-export([unmarshal/2]).

-include("legacy_structures.hrl").

%% Marshalling

-spec marshal(term(), term()) ->
    term().

marshal(details, #domain_InvoiceDetails{} = Details) ->
    genlib_map:compact(#{
        <<"product">> => marshal(str, Details#domain_InvoiceDetails.product),
        <<"description">> => marshal({maybe, str}, Details#domain_InvoiceDetails.description),
        <<"cart">> => marshal({maybe, cart}, Details#domain_InvoiceDetails.cart)
    });

marshal(cart, #domain_InvoiceCart{lines = Lines}) ->
    marshal({list, line}, Lines);

marshal(line, #domain_InvoiceLine{} = InvoiceLine) ->
    #{
        <<"product">> => marshal(str, InvoiceLine#domain_InvoiceLine.product),
        <<"quantity">> => marshal(int, InvoiceLine#domain_InvoiceLine.quantity),
        <<"price">> => hg_cash:marshal(cash, InvoiceLine#domain_InvoiceLine.price),
        <<"metadata">> => marshal(metadata, InvoiceLine#domain_InvoiceLine.metadata)
    };

marshal(metadata, Metadata) ->
    maps:fold(
        fun(K, V, Acc) ->
            maps:put(marshal(str, K), marshal(msgpack, V), Acc)
        end,
        #{},
        Metadata
    );

marshal(Term, Value) ->
    hg_msgpack_marshalling:marshal(Term, Value, ?MODULE).

%% Unmarshalling

-spec unmarshal(term(), term()) ->
    term().

unmarshal(details, #{<<"product">> := Product} = Details) ->
    #domain_InvoiceDetails{
        product     = unmarshal(str, Product),
        description = unmarshal({maybe, str}, genlib_map:get(<<"description">>, Details)),
        cart        = unmarshal({maybe, cart}, genlib_map:get(<<"cart">>, Details))
    };

unmarshal(details, ?legacy_invoice_details(Product, Description)) ->
    #domain_InvoiceDetails{
        product     = unmarshal(str, Product),
        description = unmarshal({maybe, str}, Description)
    };

unmarshal(cart, Lines) when is_list(Lines) ->
    #domain_InvoiceCart{lines = unmarshal({list, line}, Lines)};

unmarshal(line, #{
    <<"product">> := Product,
    <<"quantity">> := Quantity,
    <<"price">> := Price,
    <<"metadata">> := Metadata
}) ->
    #domain_InvoiceLine{
        product = unmarshal(str, Product),
        quantity = unmarshal(int, Quantity),
        price = hg_cash:unmarshal(cash, Price),
        metadata = unmarshal(metadata, Metadata)
    };

unmarshal(metadata, Metadata) ->
    maps:fold(
        fun(K, V, Acc) ->
            maps:put(unmarshal(str, K), unmarshal(msgpack, V), Acc)
        end,
        #{},
        Metadata
    );

unmarshal(Term, Value) ->
    hg_msgpack_marshalling:unmarshal(Term, Value, ?MODULE).