# Gavel

A multi-format auction library for Elixir: English, Dutch, Vickrey, sealed
first-price, reverse, and Japanese auctions. Built as a pure functional core
(`Gavel.Auction` + the `Gavel.Type` behaviour) with an opt-in OTP runtime
(`Gavel.Server`, a `DynamicSupervisor`, a `Registry`, and a pluggable
`Gavel.Store`).

## Install

    def deps do
      [{:gavel, "~> 0.1"}]
    end

## Quick start

    {:ok, _pid} =
      Gavel.start_auction(%{
        id: "lot-42",
        type: Gavel.Types.English,
        min_increment: Decimal.new(5),
        reserve_price: Decimal.new(100)
      })

    {:ok, _} = Gavel.place_bid("lot-42", "alice", "100")
    {:ok, _} = Gavel.place_bid("lot-42", "bob", "110")
    {:ok, auction} = Gavel.close("lot-42")
    auction.result #=> {:sold, "bob", #Decimal<110>}

## Formats

| Module | Mechanism |
|---|---|
| `Gavel.Types.English` | Open ascending; highest wins, pays own bid; supports min increment + proxy/max |
| `Gavel.Types.Dutch` | Descending clock; first to `accept/2` wins at the clock price |
| `Gavel.Types.Vickrey` | Sealed; highest wins, pays the second-highest bid |
| `Gavel.Types.SealedFirstPrice` | Sealed; highest wins, pays own bid |
| `Gavel.Types.Reverse` | Sealed procurement; lowest wins, pays own bid |
| `Gavel.Types.Japanese` | Ascending clock; last bidder standing wins via `drop_out/2` |

## Persistence

By default auctions are kept in ETS (survives a process crash, not a node
restart). Configure durability or your own backend:

    config :gavel, store: Gavel.Store.DETS, store_opts: [path: "/var/lib/gavel.dets"]

Implement `Gavel.Store` to back auctions with Postgres/Redis without Gavel
depending on your database.

## Events

Set a PubSub to receive `{:gavel, auction_id, {event, payload}}` on
`"auction:<id>"`:

    config :gavel, pubsub: MyApp.PubSub

See `docs/design.md` for the full design.

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Antonis Pishias.
