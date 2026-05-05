-- Phase 13.2 helper: generate a discriminative LongMemEval-shaped
-- synthetic dataset.
--
-- Design contract (vs. the original v1 corpus):
--   1. Questions are PARAPHRASES of the gold session — they do NOT share
--      content words. Forces the embedder to bridge synonyms (e.g. "Where
--      did I fly to last spring?" -> session that says "Charles de Gaulle
--      in March"). Keyword-only methods (FTS, hash) cannot win on alias
--      matching.
--   2. Decoys are TOPICAL near-misses, not random chatter. For a Paris
--      question, decoys mention Lyon, Brussels, Amsterdam — same domain,
--      different specific facts. Pressures top-K ranking, not just
--      top-N membership.
--   3. Each question has multiple gold-eligible sessions allowed via
--      `answer_session_ids` (single in this generator, but the bench
--      already supports lists).
--   4. Deterministic: same input -> same output. No external corpora,
--      no randomness.
--
-- Usage:
--   lua5.1 eval/_make_synthetic.lua [output_path]
--   default output: eval/data/longmemeval_synthetic.json

local cjson = require("cjson.safe")

local function turn(role, content) return { role = role, content = content } end

-- A "cluster" is a topic with shared vocabulary. Each cluster contributes:
--   * one or more (question, gold_session) pairs where the question is a
--     paraphrase of facts in the gold session (no keyword overlap).
--   * a pool of sibling decoy sessions on the same topic with different
--     specifics. The bench picks all sibling decoys + a small slice of
--     cross-cluster decoys.
--
-- Each gold/decoy session below is intentionally short (2-4 turns) to
-- match real chat-history fragments.

local CLUSTERS = {

    -- =================================================================
    { name = "european-travel",
      gold = {
        { qid = "et1",
          question = "Where did I last fly to in Europe?",
          answer   = "Paris",
          session  = {
            turn("user", "Just got back from Charles de Gaulle, the queue at passport control was awful."),
            turn("assistant", "Welcome home! How was the trip?"),
            turn("user", "Loved walking along the Seine in early March."),
          } },
        { qid = "et2",
          question = "Which Italian city did I visit for my anniversary?",
          answer   = "Florence",
          session  = {
            turn("user", "Anniversary weekend in Tuscany was perfect — saw the Duomo and ate at a tiny trattoria off Piazza Signoria."),
            turn("assistant", "Florence is wonderful that time of year."),
          } },
        { qid = "et3",
          question = "Where in Spain did I take that cooking class?",
          answer   = "Barcelona",
          session  = {
            turn("user", "The paella class in the Gothic Quarter was the highlight — chef was from Valencia originally."),
            turn("assistant", "Sounds like a fantastic afternoon in BCN."),
          } },
        { qid = "et4",
          question = "Which Dutch city did I attend the conference in?",
          answer   = "Amsterdam",
          session  = {
            turn("user", "Conference was at the RAI, took the tram from Centraal every morning."),
            turn("assistant", "Hope you got time to see the canals."),
          } },
      },
      decoys = {
        { turn("user", "Layover in Frankfurt was four hours, brutal.") },
        { turn("user", "Brussels Eurostar terminal was being renovated when I went last fall.") },
        { turn("user", "Vienna in winter is magical but the wind off the Danube is no joke.") },
        { turn("user", "Lyon's old town was nearly empty on a Tuesday morning.") },
        { turn("user", "Edinburgh hostel I stayed at had the worst kitchen.") },
      } },

    -- =================================================================
    { name = "cloud-infra",
      gold = {
        { qid = "ci1",
          question = "Which region hosts our staging Kubernetes cluster?",
          answer   = "eu-west-2",
          session  = {
            turn("user", "Reminder for ops: the staging EKS lives in London. All non-prod traffic terminates there."),
            turn("assistant", "Got it — eu-west-2 for staging EKS."),
          } },
        { qid = "ci2",
          question = "What database engine did we pick for the new analytics service?",
          answer   = "ClickHouse",
          session  = {
            turn("user", "After the bake-off the team agreed on ClickHouse for the funnel queries — the column store wins on our access pattern."),
            turn("assistant", "ClickHouse it is."),
          } },
        { qid = "ci3",
          question = "Which CI vendor did we migrate to?",
          answer   = "GitHub Actions",
          session  = {
            turn("user", "We're off CircleCI as of next sprint, everything moves to native runners on GH."),
            turn("assistant", "Migration to GitHub Actions noted."),
          } },
        { qid = "ci4",
          question = "Where do we store audit logs for compliance?",
          answer   = "S3 with object lock",
          session  = {
            turn("user", "Compliance wants WORM storage, so audit goes to a locked bucket with retention enforcement."),
            turn("assistant", "Audit logs to S3 object-lock — confirmed."),
          } },
      },
      decoys = {
        { turn("user", "Production DB is still on RDS Postgres 14, no plans to upgrade until Q4.") },
        { turn("user", "We tried Datadog APM but the price model was untenable for a team our size.") },
        { turn("user", "Terraform state lives in a separate locked bucket from app data.") },
        { turn("user", "Vault is deployed in HA mode across three AZs, mostly idle though.") },
        { turn("user", "Argo CD handles all our k8s deploys, GitOps-style.") },
        { turn("user", "Lambda cold starts on the auth path are still 800ms p99.") },
      } },

    -- =================================================================
    { name = "pets-vet",
      gold = {
        { qid = "pv1",
          question = "When is Rex's next checkup?",
          answer   = "April 18",
          session  = {
            turn("user", "Locked in the appointment for the dog at the new clinic — eighteenth of April, 2pm slot."),
            turn("assistant", "Confirmed: Rex visit on April 18 at 2pm."),
          } },
        { qid = "pv2",
          question = "What food is Mittens allergic to?",
          answer   = "chicken",
          session  = {
            turn("user", "Cat got hives again from the new wet food — turns out it's the poultry protein, not the grain."),
            turn("assistant", "So Mittens reacts to chicken-based food. Switching brands."),
          } },
        { qid = "pv3",
          question = "Which medication does the parrot take for feather picking?",
          answer   = "haloperidol",
          session  = {
            turn("user", "Bird is back on the low-dose anti-psychotic — vet says it's the only thing that actually stops the picking."),
            turn("assistant", "Haloperidol resumed, low dose."),
          } },
      },
      decoys = {
        { turn("user", "The hamster exercise wheel I bought is too small, returning it.") },
        { turn("user", "Goldfish tank pH is creeping up again, need to test the tap water.") },
        { turn("user", "Adopted a rescue rabbit last weekend, she's already bonded with the cat.") },
        { turn("user", "Dog park near the old apartment was always muddy in spring.") },
        { turn("user", "Vet bill for the dental cleaning was way more than quoted.") },
      } },

    -- =================================================================
    { name = "mobile-dev",
      gold = {
        { qid = "md1",
          question = "Which language did we choose for the Android rewrite?",
          answer   = "Kotlin",
          session  = {
            turn("user", "Final call from the platform meeting: we're going JetBrains all the way for the new native client."),
            turn("assistant", "Kotlin for Android, decision recorded."),
          } },
        { qid = "md2",
          question = "What's the minimum iOS version we support?",
          answer   = "iOS 16",
          session  = {
            turn("user", "Marketing finally agreed to drop anything older than two majors back, so floor moves up."),
            turn("assistant", "iOS 16 minimum, understood."),
          } },
        { qid = "md3",
          question = "Which framework powers our cross-platform onboarding flow?",
          answer   = "Flutter",
          session  = {
            turn("user", "Onboarding stays on the Dart-based UI toolkit since both teams already maintain it."),
            turn("assistant", "Flutter for onboarding, retained."),
          } },
      },
      decoys = {
        { turn("user", "Crashlytics shows a spike on Pixel 6 Android 14 builds.") },
        { turn("user", "Push notification delivery on iOS Focus mode is unreliable.") },
        { turn("user", "App Store review took eleven days last submission, painful.") },
        { turn("user", "Considered React Native but the bridge overhead killed the deal.") },
        { turn("user", "Internal beta uses TestFlight, external uses Firebase distribution.") },
      } },

    -- =================================================================
    { name = "health",
      gold = {
        { qid = "hl1",
          question = "What did the doctor recommend for my back pain?",
          answer   = "physiotherapy twice a week",
          session  = {
            turn("user", "Saw the spine specialist — she wants me doing PT sessions on Tuesdays and Fridays for six weeks before considering anything else."),
            turn("assistant", "Two weekly physio sessions, six-week trial."),
          } },
        { qid = "hl2",
          question = "Which supplement did the nutritionist suggest for my iron levels?",
          answer   = "ferrous bisglycinate",
          session  = {
            turn("user", "She said the chelated form is gentler on the stomach, picked up a bottle on the way home."),
            turn("assistant", "Ferrous bisglycinate added to your stack."),
          } },
        { qid = "hl3",
          question = "What's my target resting heart rate?",
          answer   = "below 60",
          session  = {
            turn("user", "Cardiologist said the goal is sub-60 BPM at rest, currently sitting around 68."),
            turn("assistant", "Target: <60 BPM resting."),
          } },
      },
      decoys = {
        { turn("user", "Migraine frequency is down since I cut afternoon coffee.") },
        { turn("user", "Allergy panel came back negative for everything except dust mites.") },
        { turn("user", "Dentist wants to redo the molar crown, not looking forward to it.") },
        { turn("user", "Sleep tracker says I'm averaging 6.2 hours, need to fix that.") },
        { turn("user", "Annual physical bloodwork all in range except vitamin D.") },
      } },

    -- =================================================================
    { name = "home-projects",
      gold = {
        { qid = "hp1",
          question = "What colour did we pick for the kitchen walls?",
          answer   = "sage green",
          session  = {
            turn("user", "Final call after the third sample swatch: we're going with the muted herby green, not the blue-grey."),
            turn("assistant", "Sage green for the kitchen walls."),
          } },
        { qid = "hp2",
          question = "What size is the new dining table?",
          answer   = "seats eight",
          session  = {
            turn("user", "The extending oak one we ordered handles eight comfortably with the leaf in."),
            turn("assistant", "Eight-seater dining table, confirmed."),
          } },
        { qid = "hp3",
          question = "Which contractor are we using for the bathroom remodel?",
          answer   = "Hendricks & Sons",
          session  = {
            turn("user", "Going with the family-run outfit on Bloor — their quote was reasonable and reviews were solid."),
            turn("assistant", "Hendricks & Sons booked for the bathroom."),
          } },
      },
      decoys = {
        { turn("user", "Garage door opener finally died, need to replace the whole unit.") },
        { turn("user", "Backyard fence is leaning after the storm, calling it in tomorrow.") },
        { turn("user", "Heat pump is humming louder than it used to, scheduling service.") },
        { turn("user", "Kids' bedroom got a fresh coat last weekend, classic off-white.") },
        { turn("user", "Considering solar panels but the payback period is still 11 years.") },
      } },

    -- =================================================================
    { name = "books",
      gold = {
        { qid = "bk1",
          question = "Which novel did the book club pick this month?",
          answer   = "Klara and the Sun",
          session  = {
            turn("user", "We landed on the Ishiguro AI one — should be a quick read for the meeting next Wednesday."),
            turn("assistant", "Klara and the Sun on the docket."),
          } },
        { qid = "bk2",
          question = "Who wrote that history book I lent you?",
          answer   = "Mary Beard",
          session  = {
            turn("user", "The Cambridge classicist's Roman empire one — she's brilliant on the politics."),
            turn("assistant", "Beard's SPQR, got it."),
          } },
      },
      decoys = {
        { turn("user", "The mystery I started on the plane was awful, abandoned at chapter four.") },
        { turn("user", "Library hold for the new Murakami finally came in.") },
        { turn("user", "Gave up on audiobooks while running, can't focus on plot.") },
        { turn("user", "Kindle battery is mysteriously dying overnight again.") },
      } },

    -- =================================================================
    { name = "cooking",
      gold = {
        { qid = "ck1",
          question = "What's the secret ingredient in grandma's chili?",
          answer   = "dark chocolate",
          session  = {
            turn("user", "She finally let it slip — a square of 70% cocoa goes in at the end, that's why nobody can replicate it."),
            turn("assistant", "Dark chocolate in the chili — secret unlocked."),
          } },
        { qid = "ck2",
          question = "Which oil should I use for the wok?",
          answer   = "peanut oil",
          session  = {
            turn("user", "Chef at the Sichuan place said groundnut is the only thing that hits a true high-heat sear without smoking."),
            turn("assistant", "Peanut oil for wok work."),
          } },
        { qid = "ck3",
          question = "What temperature does the sourdough need?",
          answer   = "78F bulk fermentation",
          session  = {
            turn("user", "Bread baker friend insisted on a warm-ish proof, around the high seventies, otherwise the rise drags out."),
            turn("assistant", "Bulk ferment at ~78F."),
          } },
      },
      decoys = {
        { turn("user", "Stand mixer dough hook attachment is missing, where did it go.") },
        { turn("user", "New chef knife arrived dull, needs a stone pass.") },
        { turn("user", "Tried the air fryer for tofu, the texture was perfect.") },
        { turn("user", "Pressure cooker beans in 22 minutes, never going back.") },
      } },

    -- =================================================================
    { name = "music",
      gold = {
        { qid = "mu1",
          question = "What strings do I use on the acoustic?",
          answer   = "phosphor bronze .012",
          session  = {
            turn("user", "Restocked the usual — coated bronze mediums, twelve gauge. Last set lasted four months."),
            turn("assistant", "Phosphor bronze .012, repurchased."),
          } },
        { qid = "mu2",
          question = "Which tuning did I learn that song in?",
          answer   = "DADGAD",
          session  = {
            turn("user", "Took me ages to figure out it was that Celtic open tuning, not standard with a capo."),
            turn("assistant", "DADGAD, noted."),
          } },
      },
      decoys = {
        { turn("user", "Amp tubes are overdue for replacement, biasing it next weekend.") },
        { turn("user", "Pedal board cleanup pulled three things I never used.") },
        { turn("user", "Mic preamp picked up some hum after the move, grounding issue.") },
        { turn("user", "Open mic at the pub had decent turnout despite the rain.") },
      } },

    -- =================================================================
    { name = "finance",
      gold = {
        { qid = "fn1",
          question = "Where is my emergency fund parked?",
          answer   = "EQ Bank savings at 4.0%",
          session  = {
            turn("user", "Moved the cash buffer to the online-only one with the variable rate, currently four flat."),
            turn("assistant", "Emergency cash at EQ, 4.0% variable."),
          } },
        { qid = "fn2",
          question = "Which broker holds the registered account?",
          answer   = "Questrade",
          session  = {
            turn("user", "TFSA finally fully transferred from the bank to the discount platform — the fee savings make it worth it."),
            turn("assistant", "Registered account at Questrade."),
          } },
        { qid = "fn3",
          question = "What's the target asset allocation for retirement?",
          answer   = "70% equities 30% bonds",
          session  = {
            turn("user", "Advisor and I settled on a fairly aggressive split given the time horizon — most in stocks, smaller bond sleeve."),
            turn("assistant", "70/30 equity-bond mix."),
          } },
      },
      decoys = {
        { turn("user", "Mortgage renewal in eighteen months, watching rates carefully.") },
        { turn("user", "Auto-debit for the monthly contribution went through fine this month.") },
        { turn("user", "Tax software estimates a small refund this year, nothing dramatic.") },
        { turn("user", "Credit card cashback program is changing categories next quarter.") },
        { turn("user", "Looked at the new high-interest checking but the minimum balance is steep.") },
      } },

    -- =================================================================
    { name = "fitness",
      gold = {
        { qid = "ft1",
          question = "What's my deadlift PR?",
          answer   = "405 pounds",
          session  = {
            turn("user", "Finally pulled four plates a side last Saturday, clean lockout, no belt drama."),
            turn("assistant", "Deadlift PR: 405 lbs."),
          } },
        { qid = "ft2",
          question = "Which marathon am I training for?",
          answer   = "Berlin",
          session  = {
            turn("user", "Booked the September race — flat course, fast field, exactly what I need for a BQ attempt."),
            turn("assistant", "Berlin marathon, September."),
          } },
        { qid = "ft3",
          question = "How many days a week is the new lifting program?",
          answer   = "four",
          session  = {
            turn("user", "Coach put me on an upper-lower split, twice each, with weekend runs filling in conditioning."),
            turn("assistant", "Four lifting days, U/L split."),
          } },
      },
      decoys = {
        { turn("user", "Foam roller is the only thing that touches my IT band.") },
        { turn("user", "Heart rate cap on Z2 days is still an annoying discipline.") },
        { turn("user", "Garmin watch strap broke, ordering the silicone replacement.") },
        { turn("user", "Climbing gym membership freeze is over, back at it next week.") },
        { turn("user", "Recovery has been better since I added creatine.") },
      } },
}

-- ---------------------------------------------------------------------------
-- Build LongMemEval rows.
--
-- For each (gold) question:
--   * answer_session = the gold session (always 1 in this generator)
--   * sibling_decoys = all sibling sessions in the same cluster's decoy
--                      pool AND the OTHER gold sessions in the same
--                      cluster (those are factually different so they
--                      function as topical near-misses)
--   * cross_decoys   = a deterministic slice of decoys from other
--                      clusters (5 by default) so the haystack still
--                      has off-topic noise.
-- ---------------------------------------------------------------------------

local function deterministic_other_decoys(this_cluster_idx, n_wanted)
    local out = {}
    local picked = 0
    local idx = this_cluster_idx
    while picked < n_wanted do
        idx = idx + 1
        if idx > #CLUSTERS then idx = 1 end
        if idx == this_cluster_idx then break end
        local d = CLUSTERS[idx].decoys[1]
        if d then
            out[#out + 1] = { cluster = CLUSTERS[idx].name, idx = 1, turns = d }
            picked = picked + 1
        end
    end
    return out
end

local rows = {}
for ci, cluster in ipairs(CLUSTERS) do
    for _, gq in ipairs(cluster.gold) do
        local hs = {}
        local gold_sid = "sess_" .. gq.qid .. "_gold"
        hs[gold_sid] = gq.session

        for _, other in ipairs(cluster.gold) do
            if other.qid ~= gq.qid then
                hs["sess_" .. gq.qid .. "_sib_" .. other.qid] = other.session
            end
        end

        for di, decoy in ipairs(cluster.decoys) do
            hs["sess_" .. gq.qid .. "_decoy_" .. di] = decoy
        end

        for ci2, x in ipairs(deterministic_other_decoys(ci, 5)) do
            hs["sess_" .. gq.qid .. "_cross_" .. ci2 .. "_" .. x.cluster] = x.turns
        end

        rows[#rows + 1] = {
            question_id        = gq.qid,
            question           = gq.question,
            answer             = gq.answer,
            question_type      = "single-session-paraphrase",
            cluster            = cluster.name,
            answer_session_ids = { gold_sid },
            haystack_sessions  = hs,
        }
    end
end

local out = arg[1] or "eval/data/longmemeval_synthetic.json"
os.execute("mkdir -p " .. (out:match("(.*)/") or "."))
local fh = assert(io.open(out, "wb"))
fh:write(cjson.encode(rows))
fh:close()
print(("wrote %s (%d questions across %d clusters)")
    :format(out, #rows, #CLUSTERS))
