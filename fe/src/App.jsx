import { useState } from "react";
import LandingPage from "./LandingPage";
import GhostSwap from "./GhostSwap";

export default function App() {
  const [page, setPage] = useState("landing");
  if (page === "app") return <GhostSwap onBack={() => setPage("landing")} />;
  return <LandingPage onLaunchApp={() => setPage("app")} />;
}
