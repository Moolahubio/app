import { Router, type IRouter } from "express";
import {
  CreateCircleBody,
  InviteToCircleBody,
  GetCircleParams,
  InviteToCircleParams,
  StartCircleParams,
  ContributeToCircleParams,
  AcceptInviteParams,
  DeclineInviteParams,
  ListCirclesResponse,
  ListInvitesResponse,
  GetCircleResponse,
  InviteToCircleResponse,
  StartCircleResponse,
  ContributeToCircleResponse,
  AcceptInviteResponse,
  DeclineInviteResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import {
  createCircle,
  listCirclesForUser,
  getCircleDetail,
  contribute,
  inviteToCircle,
  listInvitesForUser,
  acceptInvite,
  declineInvite,
  startCircle,
} from "../lib/circles";

const router: IRouter = Router();

router.get("/circles", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const circles = await listCirclesForUser(user.id);
  res.json(ListCirclesResponse.parse(circles));
});

router.get("/circles/invites", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const invites = await listInvitesForUser(user.email);
  res.json(ListInvitesResponse.parse(invites));
});

router.post("/circles", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = CreateCircleBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  let circleId: string;
  try {
    const circle = await createCircle(user.id, {
      name: parsed.data.name,
      contributionCents: parsed.data.contributionCents,
      frequency: parsed.data.frequency,
      memberEmails: parsed.data.memberEmails,
      imageUrl: parsed.data.imageUrl ?? null,
    });
    circleId = circle.id;
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Could not create circle" });
    return;
  }

  const detail = await getCircleDetail(user.id, circleId);
  res.status(201).json(GetCircleResponse.parse(detail));
});

router.get("/circles/:id", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = GetCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  const detail = await getCircleDetail(user.id, params.data.id);
  if (!detail) {
    res.status(404).json({ error: "Circle not found" });
    return;
  }

  res.json(GetCircleResponse.parse(detail));
});

router.post("/circles/:id/invite", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = InviteToCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }
  const parsed = InviteToCircleBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  try {
    await inviteToCircle(user.id, params.data.id, parsed.data.email);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Could not send invite" });
    return;
  }

  res.json(InviteToCircleResponse.parse({ ok: true }));
});

router.post("/circles/:id/start", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = StartCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  try {
    await startCircle(user.id, params.data.id);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Could not start circle" });
    return;
  }

  res.json(StartCircleResponse.parse({ ok: true }));
});

router.post("/circles/:id/contribute", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = ContributeToCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  try {
    await contribute(user.id, params.data.id);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Contribution failed" });
    return;
  }

  res.json(ContributeToCircleResponse.parse({ ok: true }));
});

router.post("/circles/invites/:id/accept", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = AcceptInviteParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  try {
    await acceptInvite(user.id, user.email, params.data.id);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Could not accept invite" });
    return;
  }

  res.json(AcceptInviteResponse.parse({ ok: true }));
});

router.post("/circles/invites/:id/decline", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = DeclineInviteParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  try {
    await declineInvite(user.email, params.data.id);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Could not decline invite" });
    return;
  }

  res.json(DeclineInviteResponse.parse({ ok: true }));
});

export default router;
