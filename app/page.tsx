import Link from "next/link";
import { Hero } from "@/components/landing/Hero";
import { HowItWorks } from "@/components/landing/HowItWorks";
import { QualificationRules } from "@/components/landing/QualificationRules";
import { OddsVsPayout } from "@/components/landing/OddsVsPayout";
import { TickerAssetSection } from "@/components/landing/TickerAssetSection";
import { WhyTryClog } from "@/components/landing/WhyTryClog";
import { FAQ } from "@/components/landing/FAQ";
import { TokenTable } from "@/components/explore/TokenTable";
import { RandomnessTrust } from "@/components/token/RandomnessTrust";

export default function HomePage() {
  return (
    <>
      <Hero />

      <section className="content-container py-14">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="font-display text-xl font-semibold text-ink">Live memes</h2>
          <Link href="/explore" className="text-sm font-medium text-cyan hover:underline">
            See more →
          </Link>
        </div>
        <TokenTable limit={6} />
      </section>

      <div className="border-t border-border">
        <HowItWorks />
      </div>

      <QualificationRules />

      <div className="border-t border-border">
        <OddsVsPayout />
      </div>

      <TickerAssetSection />

      <div className="border-t border-border">
        <WhyTryClog />
      </div>

      <div className="border-t border-border py-16">
        <div className="content-container">
          <h2 className="mb-6 font-display text-2xl font-semibold text-ink sm:text-3xl">
            Fair by design
          </h2>
          <RandomnessTrust />
        </div>
      </div>

      <div className="border-t border-border">
        <FAQ />
      </div>
    </>
  );
}
