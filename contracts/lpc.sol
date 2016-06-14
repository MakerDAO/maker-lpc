import 'dappsys/auth.sol';
import 'feedbase/feedbase.sol'; // for link type TODO refactor
import 'feedbase/user.sol';
import 'maker-user/user.sol';

import 'assertive.sol';
import 'fallback_failer.sol';
import 'type.sol';

// Notes:
// * Deploy via the factory
// * needs a dai balance to pay for feeds. Consume feeds for free by
//   setting `max_feed_price` to 0 and waiting for someone else to read it first.
// * each configuration entry specifies details for a one-way exchange.
//   The price function is linear function with an error offset. So the
//   cost function is quadratic, and buyReward grows like sqrt(n)
contract BasicLiquidityProvider is
    LPCType,
    Assertive,
    DSAuth,
    FallbackFailer,
    FeedBaseUser // is MakerUser
{
    function BasicLiquidityProvider(FeedBase fb, MakerUserLinkType maker)
             FeedBaseUser(fb, maker)
    {}

    // == Events == //
    event MarketToggled( bytes32 indexed selling_what, bytes32 indexed accepting_what, bool indexed enabled );

    // == Data == //
    // Config mapping
    //   lpc: sell_what -> buy_what -> config
    //   user: buy_what -> sell_what -> config
    mapping(bytes32=>mapping(bytes32=>MarketConfig)) public _configs;
    struct MarketConfig {
        bool enabled;
        // * feed_id should provide a feed for the price at which LPC wants
        //   to sell `sell_what` denominated in `buy_what`.
        // * The assumed precision for assets and prices is 10^18 (same as ETH).
        //   Other precisions can be supported by scaling arguments appropriately.
        // * The feed can be inverted (`feed/(10^18)`) by setting `invert_feed`.
        uint64 feed_id;
        bool invert_feed;
        uint max_feed_price;

        // these parameters are for a function hard-coded into `buyReward`. A better
        // lpc would allow you to specify `a buyReward` provider address for things
        // like logarithmic market makers or sourcing liquidity from
        // other contracts
        uint error;
        uint backoff_rate;
        uint slope;
    }


    // == User-facing functions ==

    // Throws for these failure modes:
    //  * feed is expired (see feedbase dapp)
    //  * not enough dai to pay for feed (see feedbase dapp)
    //  * not enough approval to transfer `spend_how_much` of `buy_with` from sender (see maker dapp)
    //  * not enough of the asset to transfer `bought_amount` of `buy_what` to sender (see maker dapp)
    function buy(bytes32 buy_what, uint buy_how_much, bytes32 buy_with)
             returns (uint buy_cost)
    {
        assert(buy_how_much > 0);
        assert(buy_what != 0x0);
        assert(buy_with != 0x0);

        var config = _configs[buy_what][buy_with];
        approve(_feedbase, config.max_feed_price, "DAI");
        var feed_price = uint(_feedbase.get(config.feed_id));
        if( config.invert_feed ) {
            feed_price = invert(feed_price);
        }
        buy_cost = buyCost(feed_price, buy_what, buy_how_much, buy_with);
        transferFrom(msg.sender, this, buy_cost, buy_with);
        transfer(msg.sender, buy_how_much, buy_what);
    }
    function buyCost( uint feed_price
                    , bytes32 buy_what
                    , uint buy_how_much
                    , bytes32 buy_with )
             constant
             returns (uint buy_cost)
    {
        var config = _configs[buy_what][buy_with];
        var use_price = feed_price + config.error;
        var price = buy_how_much * feed_price / toWei(1);
        var penalty = config.slope * (buy_how_much**2) / (toWei(1)**2);
        return price + penalty;
    }

    // == Protected functions. == //
    // These can be managed by a contract that allows things like
    // liquidity pooling or revenue sharing.
    function deposit(uint how_much, bytes32 what)
        auth()
    {
        transferFrom(msg.sender, this, how_much, what);
    }
    function withdraw(uint how_much, bytes32 what)
        auth()
    {
        transfer(msg.sender, how_much, what);
    }
    function setConfig( bytes32 sell_what
                      , bytes32 accept_what
                      , bool enabled
                      , uint64 feed_id
                      , bool invert_feed
                      , uint max_feed_price
                      , uint error
                      , uint slope )
        auth()
    {
        assert(sell_what != 0x0);
        assert(accept_what != 0x0);

        MarketConfig memory config;
        config.enabled = enabled;
        config.feed_id = feed_id;
        config.invert_feed = invert_feed;
        config.max_feed_price = max_feed_price;
        config.error = error;
        config.slope = slope;
        _configs[sell_what][accept_what] = config;
        MarketToggled(sell_what, accept_what, enabled);
    }
    // waste less gas toggling
    function setEnabled(bytes32 sell_what, bytes32 accept_what, bool enabled)
        auth()
    {
        assert(sell_what != 0x0);
        assert(accept_what != 0x0);

        _configs[sell_what][accept_what].enabled = enabled;
        MarketToggled(sell_what, accept_what, enabled);
    }

    // == helpers == //
    function invert(uint a) internal constant returns (uint b) {
        b = toWei(10**18)/a;
    }
}
