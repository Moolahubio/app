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
  DeleteCircleParams,
  ListCirclesResponse,
  ListInvitesResponse,
  GetCircleResponse,
  InviteToCircleResponse,
  StartCircleResponse,
  ContributeToCircleResponse,
  AcceptInviteResponse,
  DeclineInviteResponse,
  DeleteCircleResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { sendError } from "../lib/errors";
import { ObjectStorageService } from "../lib/objectStorage";
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
  deleteCircle,
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
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const imageUrl = parsed.data.imageUrl;
  if (imageUrl != null && imageUrl !== "") {
    // Only a real, allowlisted internal uploaded image may be stored — never an
    // arbitrary external URL (which would be fetched in other members' browsers:
    // tracking / SSRF) nor a disguised non-image upload.
    const objectStorage = new ObjectStorageService();
    const usable = await objectStorage.isUsableImageObject(imageUrl);
    if (!usable) {
      res.status(400).json({ error: "Invalid circle image." });
      return;
    }
    // A circle cover image is shared with every circle member, so it is a
    // public display asset. Binding an ACL policy is still required: the serving
    // route refuses to read any object that has no policy (e.g. a raw upload
    // that was never attached to anything). Claiming fails if the object is
    // already owned by someone else, preventing object takeover by path.
    const claimed = await objectStorage.claimObjectEntityForOwner(
      imageUrl,
      user.id,
      "public",
    );
    if (!claimed) {
      res.status(400).json({ error: "Invalid circle image." });
      return;
    }
  }

  let circleId: string;
  try {
    const circle = await createCircle(user.id, {
      name: parsed.data.name,
      type: parsed.data.type,
      contributionCents: parsed.data.contributionCents,
      numRounds: parsed.data.numRounds,
      frequency: parsed.data.frequency,
      memberEmails: parsed.data.memberEmails,
      imageUrl: imageUrl ?? null,
    });
    circleId = circle.id;
  } catch (e) {
    sendError(res, e, "Could not create circle");
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
    res.status(400).json({ error: "Invalid request" });
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
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  const parsed = InviteToCircleBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await inviteToCircle(user.id, params.data.id, parsed.data.email);
  } catch (e) {
    sendError(res, e, "Could not send invite");
    return;
  }

  res.json(InviteToCircleResponse.parse({ ok: true }));
});

router.post("/circles/:id/start", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = StartCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await startCircle(user.id, params.data.id);
  } catch (e) {
    sendError(res, e, "Could not start circle");
    return;
  }

  res.json(StartCircleResponse.parse({ ok: true }));
});

router.post("/circles/:id/delete", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = DeleteCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await deleteCircle(user.id, params.data.id);
  } catch (e) {
    sendError(res, e, "Could not delete circle");
    return;
  }

  res.json(DeleteCircleResponse.parse({ ok: true }));
});

router.post("/circles/:id/contribute", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = ContributeToCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await contribute(user.id, params.data.id);
  } catch (e) {
    sendError(res, e, "Contribution failed");
    return;
  }

  res.json(ContributeToCircleResponse.parse({ ok: true }));
});

router.post("/circles/invites/:id/accept", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = AcceptInviteParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await acceptInvite(user.id, user.email, params.data.id);
  } catch (e) {
    sendError(res, e, "Could not accept invite");
    return;
  }

  res.json(AcceptInviteResponse.parse({ ok: true }));
});

router.post("/circles/invites/:id/decline", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = DeclineInviteParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await declineInvite(user.email, params.data.id);
  } catch (e) {
    sendError(res, e, "Could not decline invite");
    return;
  }

  res.json(DeclineInviteResponse.parse({ ok: true }));
});

export default router;
