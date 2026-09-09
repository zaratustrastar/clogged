import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { Hero } from "@/components/landing/Hero";
import { TwoWaysIn } from "@/components/landing/TwoWaysIn";
import { QualificationRules } from "@/components/landing/QualificationRules";
import { OddsVsPayout } from "@/components/landing/OddsVsPayout";
import { TickerAssetSection } from "@/components/landing/TickerAssetSection";
import { ClogMechanicSection } from "@/components/landing/ClogMechanicSection";
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
        <TwoWaysIn />
      </div>

      <QualificationRules />

      <div className="border-t border-border">
        <OddsVsPayout />
      </div>

      <TickerAssetSection />

      <div className="border-t border-border">
        <ClogMechanicSection />
      </div>

      <div className="border-t border-border py-16">
        <div className="content-container">
          <h2 className="mb-6 font-display text-2xl font-semibold text-ink sm:text-3xl">
            The winner is not chosen by CLOG.
          </h2>
          <RandomnessTrust />
        </div>
      </div>

      <div className="border-t border-border">
        <FAQ />
      </div>

      <div className="border-t border-border py-14">
        <div className="content-container flex flex-col items-center gap-4 text-center">
          <p className="text-sm text-ink-dim">Launch a meme, or back one already live.</p>
          <div className="flex flex-wrap items-center justify-center gap-3">
            <Link href="/launch">
              <Button size="lg">Launch a meme</Button>
            </Link>
            <Link href="/explore">
              <Button size="lg" variant="secondary">
                Explore memes
              </Button>
            </Link>
          </div>
        </div>
      </div>
    </>
  );
}
