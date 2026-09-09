import Link from "next/link";
import { Hero } from "@/components/landing/Hero";
import { HowItWorks } from "@/components/landing/HowItWorks";
import { FAQ } from "@/components/landing/FAQ";
import { TokenTable } from "@/components/explore/TokenTable";

export default function HomePage() {
  return (
    <>
      <Hero />

      <section className="content-container py-14">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="font-display text-xl font-semibold text-ink">Tokens</h2>
          <Link href="/explore" className="text-sm font-medium text-cyan hover:underline">
            See more →
          </Link>
        </div>
        <TokenTable limit={6} />
      </section>

      <div className="border-t border-border">
        <HowItWorks />
      </div>
      <div className="border-t border-border">
        <FAQ />
      </div>
    </>
  );
}
