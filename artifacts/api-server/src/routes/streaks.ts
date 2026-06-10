import { Router, type IRouter } from "express";
import {
  GetStreaksResponse,
  SetStreakRemindersBody,
  SetStreakRemindersResponse,
  SetStreakFrequencyBody,
  SetStreakFrequencyResponse,
  StartStreakVacationBody,
  StartStreakVacationResponse,
  EndStreakVacationResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { sendError } from "../lib/errors";
import {
  getStreakOverview,
  setReminderOptIn,
  setStreakFrequency,
  startVacation,
  endVacation,
} from "../lib/streaks";

const router: IRouter = Router();

router.get("/streaks", requireAuth, async (req, res): Promise<void> => {
  try {
    const user = (req as AuthRequest).user;
    const overview = await getStreakOverview(user.id);
    res.json(GetStreaksResponse.parse(overview));
  } catch (e) {
    sendError(res, e, "Failed to load streaks");
  }
});

router.post("/streaks/reminders", requireAuth, async (req, res): Promise<void> => {
  try {
    const user = (req as AuthRequest).user;
    const body = SetStreakRemindersBody.parse(req.body);
    const result = await setReminderOptIn(user.id, body.optIn);
    res.json(SetStreakRemindersResponse.parse(result));
  } catch (e) {
    sendError(res, e, "Failed to update reminders");
  }
});

router.post("/streaks/frequency", requireAuth, async (req, res): Promise<void> => {
  try {
    const user = (req as AuthRequest).user;
    const body = SetStreakFrequencyBody.parse(req.body);
    const overview = await setStreakFrequency(user.id, body.frequency);
    res.json(SetStreakFrequencyResponse.parse(overview));
  } catch (e) {
    sendError(res, e, "Failed to change streak frequency");
  }
});

router.post("/streaks/vacation", requireAuth, async (req, res): Promise<void> => {
  try {
    const user = (req as AuthRequest).user;
    const body = StartStreakVacationBody.parse(req.body);
    const overview = await startVacation(user.id, body.days);
    res.json(StartStreakVacationResponse.parse(overview));
  } catch (e) {
    sendError(res, e, "Failed to start vacation");
  }
});

router.post("/streaks/vacation/end", requireAuth, async (req, res): Promise<void> => {
  try {
    const user = (req as AuthRequest).user;
    const overview = await endVacation(user.id);
    res.json(EndStreakVacationResponse.parse(overview));
  } catch (e) {
    sendError(res, e, "Failed to end vacation");
  }
});

export default router;
