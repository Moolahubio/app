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
import { ObjectAccessGroupType, ObjectPermission } from "../lib/objectAcl";
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
  const objectStorage = new ObjectStorageService();
  if (imageUrl != null && imageUrl !== "") {
    // Only a real, allowlisted internal uploaded image may be stored — never an
    // arbitrary external URL (which would be fetched in other members' browsers:
    // tracking / SSRF) nor a disguised non-image upload.
    const usable = await objectStorage.isUsableImageObject(imageUrl);
    if (!usable) {
      res.status(400).json({ error: "Invalid circle image." });
      return;
    }
    // A circle cover image is shared with every circle member, but scoped to
    // circle membership only — not globally readable by any authenticated user.
    // Claim as private; the ACL will be updated with a CIRCLE_MEMBER rule once
    // the circle is created and its ID is known. Claiming fails if the object
    // is already owned by someone else, preventing object takeover by path.
    const claimed = await objectStorage.claimObjectEntityForOwner(
      imageUrl,
      user.id,
      "private",
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
      targetPayoutCents: parsed.data.targetPayoutCents,
      groupSize: parsed.data.groupSize,
      frequency: parsed.data.frequency,
      memberEmails: parsed.data.memberEmails,
      imageUrl: imageUrl ?? null,
    });
    circleId = circle.id;
  } catch (e) {
    sendError(res, e, "Could not create circle");
    return;
  }

  // Scope the circle image to members of this specific circle. The owner
  // (creator) already has access via the owner field; this rule grants read
  // access to any member who joins later.
  if (imageUrl != null && imageUrl !== "") {
    try {
      await objectStorage.trySetObjectEntityAclPolicy(imageUrl, {
        owner: user.id,
        visibility: "private",
        aclRules: [
          {
            group: { type: ObjectAccessGroupType.CIRCLE_MEMBER, id: circleId },
            permission: ObjectPermission.READ,
          },
        ],
      });
    } catch (e) {
      // Non-fatal: the circle was created successfully; the image just falls
      // back to owner-only access (the creator can still view it).
      req.log.error({ err: e }, "Failed to set circle image ACL");
    }
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
