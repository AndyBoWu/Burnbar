import { redirect } from "next/navigation";

// Bare `/leaderboard` defaults to the daily ranking.
export default function LeaderboardIndex() {
  redirect("/leaderboard/daily");
}
