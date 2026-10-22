import { AutomationSection } from './AutomationSection';
import { HeroOverview } from './HeroOverview';
import {
  ArchitectureSection,
  CallToActionSection,
  ExtensionsSection,
  FeaturesSection,
  SecuritySection,
  SiteFooter,
  StartSection,
} from './HomeSections';
import { IconSprite } from './IconSprite';
import { SiteHeader } from './SiteHeader';
import { useHomeMotion } from './useHomeMotion';

/** Ghép các vùng của trang chủ theo đúng thứ tự trong nguyên mẫu HTML. */
export function HomePage() {
  useHomeMotion();

  return (
    <>
      <a className="skip-link" href="#top">Bỏ qua đến nội dung chính</a>
      <IconSprite />
      <div id="progress" />
      <SiteHeader />
      <main id="top" tabIndex={-1}>
        <HeroOverview />
        <FeaturesSection />
        <ExtensionsSection />
        <AutomationSection />
        <ArchitectureSection />
        <StartSection />
        <SecuritySection />
        <CallToActionSection />
      </main>
      <SiteFooter />
    </>
  );
}
