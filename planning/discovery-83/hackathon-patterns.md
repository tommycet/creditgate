# Hackathon Winning Patterns & Submission Best Practices

> Research compiled for CreditGate — Flare Summer Signal (Deadline: Aug 14, 2026)
> Sources: DoraHacks official guides, JetBrains judging table post, Chainlink tips, HackerEarth, HackQuest, Reddit r/hackathon, Flare grants page, judge interviews.

---

## 1. What Judges Actually Care About

### From Real Judge Interviews (JetBrains x Codex Hackathon, June 2026)

Judges were unanimous on these priorities:

1. **Start with the problem, not the tech.** Every judge said this. Jono Bacon (Stateshift CEO): "Say what the problem is that you're solving. You need to get your audience of judges sharing your frustration with the problem." Avi Press (Scarf CEO): "Always be very clear about what problem you're solving... often people skip it because they're excited about the tech." Bonnie Xu (OpenAI): "Don't start with 'what's the coolest new tool I can use?' but with 'what's something I can build now that I probably couldn't have built before?'"

2. **Scope down to one thing.** The best projects do one thing really well rather than five things halfway. "Beware of scope creep and feature-itis." Colin Lowenberg (Nebius): "Your demo should be the focus. It should show what your app does in one flow. If it's too long, cut down on your features."

3. **Make the demo the whole pitch.** You have minutes, not hours. Jono's rule: show something working within 90 seconds. Pre-fill data, mock slow API calls, remove every place the demo could stall. "Being straightforward about what works and what doesn't reads as confidence."

4. **Rehearse.** Colin: "Visualize yourself winning and work backwards from there." Teams that practice look like they practiced.

5. **Let enthusiasm show.** "A team clearly enjoying its own project is more convincing than a team grinding through a script."

### From DoraHacks (Official Hackathon Platform)

From their guide on good submissions:

- **Read the requirements thoroughly** before starting — missing a required field can disqualify you before judging begins.
- **Show the work, not the hype.** Use the 3W1H model: What problem? Why does it matter? Who is it for? How does it work? "Substance beats buzzwords every time."
- **Highlight what makes your project stand out.** If a judge only reads your first two paragraphs, they should understand what's worth attention.
- **Make eligibility obvious.** Spell out exactly how you use the required technology. Don't make judges hunt through code to verify you're using Flare.
- **Make everything functional.** Broken links, inaccessible repos, typo'd emails — judges can only evaluate what they can see.
- **The ForestGuard Agent case study:** Lead with clarity, not buzzwords; break down how the system works step-by-step; make sponsor tool usage explicit; be specific about the tech stack. "Specificity builds credibility."

### From Reddit r/hackathon (Real Winners)

- "Read the rubric well and get a good understanding of the given problem statement." — r/hackathon
- Winning teams "don't start from scratch, they reuse ideas, frameworks, learnings" and "prepare before the hackathon even starts."
- "Teams that pick simpler ideas but execute perfectly" beat teams with complex ideas that don't finish.
- "Knowing who the judges are and how you present to them become critical points of information." Judges need not be technical — know your audience.

### From HackerEarth (2026 Hackathon Trends)

- "AI is table stakes, not a differentiator." Judges have seen a hundred GPT wrappers.
- "Impact themes are winning rubrics." Climate, healthcare, financial inclusion — organizers weight these heavily.
- "A technically simpler project that nails an impact theme often beats a more complex project that ignores it."
- "Teams that stop coding early and rehearse their pitch consistently outperform teams with stronger code."

---

## 2. Submission Patterns That Win

### The Winning Formula (Synthesized from All Sources)

| Element | What Winners Do | What Losers Do |
|---------|----------------|----------------|
| **Problem** | Lead with a specific, relatable pain point | Start with tech stack or "revolutionary" claims |
| **Scope** | One feature, end-to-end, polished | Five features, half-working |
| **Demo** | 90-second working flow, pre-filled, no stalls | Long walkthrough with broken links |
| **Flare Integration** | Explicit section showing each primitive's role | Buried in code, judges have to dig |
| **New Work** | Clear "before/after" of what was built during hackathon | Unclear what's new vs. pre-existing |
| **Presentation** | Practiced, timed, enthusiastic | Unrehearsed, reading from notes |
| **Code** | Clean, documented, tests passing, public repo | Private repo, broken links, no README |

### Key Submission Checklist (From HackQuest + Chainlink)

1. ✅ Deployed on correct testnet (Coston2 for Flare)
2. ✅ Smart contract addresses + scan URLs provided
3. ✅ Demo video (3-5 min) showing the flow
4. ✅ Live demo link (if possible)
5. ✅ Public GitHub repo with clean README
6. ✅ Architecture diagram
7. ✅ Explanation of Flare integration (not just "we used Flare")
8. ✅ What was newly built vs. pre-existing
9. ✅ Roadmap / next steps
10. ✅ All links tested and working

### The "Why It Matters" Factor

Chainlink's guide emphasizes this strongly: "Judges will favour submissions that clearly address these questions in a specific, positive, and meaningful way: Why does this project matter? Who benefits? What's the bigger impact?"

---

## 3. What We're Doing Right (CreditGate Assessment)

Based on CreditGate's current state (146 tests, 12 suites, 8 invariants, deployed on Coston2):

### ✅ Strong Product Usefulness
- Solves a real problem: "Billions of dollars of XRP sit idle on Flare as FXRP collateral — inaccessible for credit."
- Real user pain: "XRP holders won't sell their position, and can't borrow against it without granting a centralized credit bureau visibility into their finances."
- Clear target user: XRP holders wanting to borrow against FXRP without doxxing their finances.

### ✅ Excellent Flare Integration (Deep, Not Superficial)
- Uses **4 Flare primitives** load-bearing: FAssets (FXRP), FTSOv2, FCC, FDC
- Each primitive has a documented role with "Load-bearing?" classification
- Contract addresses verified live on Coston2 via ContractRegistry
- This directly addresses the "Flare integration quality" judging criterion

### ✅ Strong Technical Execution
- 146 tests across 12 suites
- 8 invariant tests
- Edge case, reentrancy, malicious reentrancy, auction, LTV, trigger, views, FDC-fixture, and Go-TEE-compat test suites
- Source verified on Coston2 explorer
- Architecture documented in ARCHITECTURE.md (35KB)

### ✅ Clear "Built During Hackathon" Story
- README explicitly shows what existed before vs. what was newly built
- SUBMISSION.md exists for detailed submission breakdown
- PROGRAM-SUMMARY.md provides program context

### ✅ Documentation Quality
- README.md: 14KB with tables, code blocks, quick start
- ARCHITECTURE.md: 35KB deep technical architecture
- DEMO.md: 9.8KB demo guide
- SUBMISSION.md: 16KB submission document
- CONTRIBUTING.md: 11KB contributor guide
- PROGRAM-SUMMARY.md: 7.6KB program summary
- Evidence directory exists with screenshots/artifacts

### ✅ Frontend Exists
- Next.js + wagmi + RainbowKit frontend
- Docs page at frontend/src/app/docs/page.tsx

### ✅ Dual Bounty Targeting
- Primary: Bounty 2 (Confidential Compute Apps) — FCC integration
- Secondary: Bounty 1 (Interoperable Asset Products) — FAssets/FXRP
- Clear narrative: "the only Bounty 2 submission binding private eligibility (FCC) → public cross-chain verification (FDC) in a single product flow"

---

## 4. What We Could Improve

### ⚠️ Demo Polish (Critical for Last 7 Days)
- **DEMO.md exists but we need to verify it's actually runnable.** Judges can't evaluate what they can't see.
- **90-second demo flow** — need to ensure the core flow works end-to-end without stalls. The JetBrains judges were emphatic: "Mock everything you can and make sure all your forms are filled and your back and forth flows with the user are smooth."
- **Video demo** — no evidence of a recorded demo video yet. This is the #1 most important deliverable after the working code. Chainlink: "The video is an extremely important part of a hackathon submission."

### ⚠️ Presentation Materials
- No pitch deck or slide deck found in the repo. Even for a virtual hackathon, a clear 3-minute walkthrough structure helps.
- Need a "problem → solution → demo → Flare integration → roadmap" narrative arc.

### ⚠️ Live Demo Accessibility
- Frontend exists but need to verify it's deployed and accessible at a URL judges can visit.
- Chainlink: "Go above and beyond by offering the judges and other developers a live working demo."

### ⚠️ DoraHacks BUIDL Page
- Need to verify the project is properly submitted on DoraHacks with all required fields filled.
- DoraHacks judges browse BUIDLs in a specific interface — the submission text must be self-contained and clear.

### ⚠️ Community Engagement
- 444 hackers registered. Active participation in the Flare Hackathon Telegram Group (https://t.me/+5Vn6ZKhr6KI3NjIx) could build visibility.
- No evidence of social media posts or community traction signals.
- The hackathon page specifically encourages sharing: "early usage, community interest, pilot users, partner conversations, or traction signals."

---

## 5. Quick Wins for the Last 7 Days (Deadline: Aug 14)

### Days 1-2: Demo & Video (CRITICAL)
- [ ] **Record a 3-minute demo video** showing the full flow: deposit FXRP → get FCC attestation → draw USDT0 loan → repay on XRPL → collateral released. Voiceover explaining each step.
- [ ] **Pre-fill all data** in the demo so judges see a smooth flow, not loading screens.
- [ ] **Deploy frontend** to a public URL (Vercel/Netlify) so judges can interact live.
- [ ] **Test every link** in SUBMISSION.md — repo, demo, explorer links, video.

### Day 3: Submission Polish
- [ ] **Write the DoraHacks BUIDL submission text** following the 3W1H model: What problem? Why does it matter? Who is it for? How does it work?
- [ ] **Explicit Flare integration section** — don't make judges search for it. List each primitive with its role.
- [ ] **Add "What was newly built" section** — clearly separate pre-existing vs. hackathon work.
- [ ] **Add roadmap** — what's next after the hackathon? This shows "future potential" which is a judging criterion.

### Day 4: Social & Community
- [ ] **Post in Flare Hackathon Telegram** introducing CreditGate and asking for feedback.
- [ ] **Share on Twitter/X** with @FlareDevHub and hackathon-relevant hashtags.
- [ ] **Engage with other builders** — judges notice community activity.

### Day 5: Final Verification
- [ ] **Run `forge test`** and confirm 141/141 pass.
- [ ] **Verify on-chain** — contract addresses match Coston2 explorer.
- [ ] **Check FCC handler** — Go service starts and returns valid EIP-191 attestation.
- [ ] **End-to-end walkthrough** — from blank browser to completed loan flow.

### Day 6: Submission
- [ ] **Submit on DoraHacks** with all required fields.
- [ ] **Double-check bounty selection** — Bounty 2 (primary) + Bounty 1 (secondary).
- [ ] **Verify submission is visible** on the hackathon BUIDL page.

### Day 7: Buffer
- [ ] **Rehearse the pitch** (even for virtual submission, a clear narrative matters).
- [ ] **Final link check** — everything works.
- [ ] **Rest.** Don't make last-minute breaking changes.

---

## 6. Flare Grants Program (Post-Hackathon Opportunity)

Flare has a **Grants Program** (https://flare.network/resources/grants) that could be a path for CreditGate after the hackathon:

- **100 grants awarded** across 21 countries
- **Token grants** for builders with products aligned with Flare's vision
- **Google Cloud credits** up to $200K ($350K for AI projects)
- **Co-marketing campaigns** with Flare
- **Technical assistance** from the Flare team
- **Advisory assistance** for strategic guidance

**Selection criteria:**
1. Uniqueness of the project
2. Benefit to the Flare ecosystem
3. Team's ability to execute (go-to-market strategy, roadmap, milestones)
4. Integration of FTSO or FDC
5. Previous blockchain development experience

**Application process:** Online form → Screening → Milestone definition → Contract → Milestone check-ins → Funds awarded

**Action item:** After the hackathon, regardless of outcome, apply to Flare Grants with a refined proposal. A hackathon win or strong showing strengthens the application significantly.

---

## 7. Sources

| Source | URL | Key Insight |
|--------|-----|-------------|
| Flare Summer Signal Detail | https://dorahacks.io/hackathon/flaresummersignal/detail | Judging criteria, prizes, submission requirements |
| JetBrains Judging Table | https://blog.jetbrains.com/ai/2026/06/how-to-win-a-hackathon-notes-from-the-judging-table | Problem-first, scope down, demo is everything |
| DoraHacks Good Submission | https://dorahacks.io/blog/news/good-hackathon-submission | 3W1H model, eligibility visibility, functionality |
| Chainlink Blockchain Tips | https://blog.chain.link/blockchain-hackathon-tips | UI first impression, video critical, explain why it matters |
| HackQuest Best Practices | https://www.hackquest.io/blog/Best-Practices-for-Successful-Web3-Hackathon-Project-Submissions | Deployment verification, documentation, demo video |
| HackerEarth 2026 Ideas | https://www.hackerearth.com/blog/hackathon-ideas | AI table stakes, impact themes winning, rehearse pitch |
| Hackathon.com Tips | https://tips.hackathon.com/article/5-tips-for-a-winning-submission-at-a-blockchain-hackathon | Submit even incomplete, simple > complex, explain importance |
| Reddit r/hackathon | Multiple threads | Read rubric, know judges, execute perfectly on simple ideas |
| Flare Grants | https://flare.network/resources/grants | Post-hackathon funding path, Google Cloud credits |
