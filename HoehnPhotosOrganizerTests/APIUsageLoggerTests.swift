import Testing
@testable import HoehnPhotosOrganizer

struct APIUsageLoggerTests {

    // Pricing tiers (per 1M tokens) encoded in APIUsageLogger.estimateCost:
    //   haiku:  $1.00 input / $5.00 output
    //   sonnet: $3.00 input / $15.00 output
    //   opus:   $15.00 input / $75.00 output
    //   unknown: falls back to haiku rates

    @Test
    func testHaikuPricingComputesCorrectly() {
        // 1 000 000 input @ $1/MTok + 1 000 000 output @ $5/MTok = $6.00
        let cost = APIUsageLogger.estimateCost(model: "claude-haiku-4-5-20251001",
                                               input: 1_000_000, output: 1_000_000)
        #expect(abs(cost - 6.0) < 1e-9, "Haiku: 1M input + 1M output must cost $6.00")
    }

    @Test
    func testSonnetPricingComputesCorrectly() {
        // 1 000 000 input @ $3/MTok + 1 000 000 output @ $15/MTok = $18.00
        let cost = APIUsageLogger.estimateCost(model: "claude-sonnet-4-6",
                                               input: 1_000_000, output: 1_000_000)
        #expect(abs(cost - 18.0) < 1e-9, "Sonnet: 1M input + 1M output must cost $18.00")
    }

    @Test
    func testOpusPricingComputesCorrectly() {
        // 1 000 000 input @ $15/MTok + 1 000 000 output @ $75/MTok = $90.00
        let cost = APIUsageLogger.estimateCost(model: "claude-opus-4-7",
                                               input: 1_000_000, output: 1_000_000)
        #expect(abs(cost - 90.0) < 1e-9, "Opus: 1M input + 1M output must cost $90.00")
    }

    @Test
    func testUnknownModelDefaultsToHaikuPricing() {
        let costUnknown = APIUsageLogger.estimateCost(model: "gpt-4o",
                                                      input: 1_000_000, output: 1_000_000)
        let costHaiku   = APIUsageLogger.estimateCost(model: "claude-haiku-4-5-20251001",
                                                      input: 1_000_000, output: 1_000_000)
        #expect(abs(costUnknown - costHaiku) < 1e-9,
                "Unrecognised model identifier must fall back to haiku pricing")
    }

    @Test
    func testZeroTokensProduceZeroCost() {
        for model in ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-7"] {
            let cost = APIUsageLogger.estimateCost(model: model, input: 0, output: 0)
            #expect(cost == 0.0, "Zero tokens must produce $0.00 cost for model \(model)")
        }
    }
}
