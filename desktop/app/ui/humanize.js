// humanizedDate() from DashboardWindowView.swift.
function humanizedDate(iso) {
  const date = new Date(iso);
  const now = new Date();
  const diff = (now - date) / 1000;
  if (diff < 60) return "now";
  if (diff < 3600) return `${Math.floor(diff / 60)} min ago`;
  const hm = date.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const days = Math.round((day(now) - day(date)) / 86400000);
  if (days === 0) return `today, ${hm}`;
  if (days === 1) return `yesterday, ${hm}`;
  if (days < 7) return `${date.toLocaleDateString("en-US", { weekday: "short" }).toLowerCase()} ${hm}`;
  return `${date.getMonth() + 1}/${date.getDate()} ${hm}`;
}
window.humanizedDate = humanizedDate;
