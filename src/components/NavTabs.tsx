import type { AppTab } from "../types";

const tabs: { id: AppTab; label: string }[] = [
  { id: "monitor", label: "Monitor" },
  { id: "train", label: "Train" },
  { id: "inference", label: "Inference" }
];

interface NavTabsProps {
  activeTab: AppTab;
  onChange: (tab: AppTab) => void;
}

export function NavTabs({ activeTab, onChange }: NavTabsProps) {
  return (
    <nav className="h-10 border-b-[0.5px] border-app-border px-5 dark:border-app-darkBorder" aria-label="Main tabs">
      <div className="flex h-full items-end gap-6">
        {tabs.map((tab) => {
          const active = tab.id === activeTab;
          return (
            <button
              key={tab.id}
              type="button"
              onClick={() => onChange(tab.id)}
              className={[
                "focus-ring relative h-full px-0 text-[13px] transition-colors",
                active ? "text-app-ink dark:text-app-darkInk" : "text-app-secondary hover:text-app-ink dark:text-app-darkSecondary dark:hover:text-app-darkInk"
              ].join(" ")}
              aria-current={active ? "page" : undefined}
            >
              {tab.label}
              <span
                className={[
                  "absolute inset-x-0 bottom-0 h-px transition-opacity",
                  active ? "bg-app-ink opacity-100 dark:bg-app-darkInk" : "opacity-0"
                ].join(" ")}
                aria-hidden="true"
              />
            </button>
          );
        })}
      </div>
    </nav>
  );
}
