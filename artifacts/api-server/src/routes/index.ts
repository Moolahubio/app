import { Router, type IRouter } from "express";
import healthRouter from "./health";
import authRouter from "./auth";
import dashboardRouter from "./dashboard";
import walletRouter from "./wallet";
import circlesRouter from "./circles";
import goalsRouter from "./goals";
import learnRouter from "./learn";
import activityRouter from "./activity";
import notificationsRouter from "./notifications";
import profileRouter from "./profile";
import storageRouter from "./storage";
import passkeysRouter from "./passkeys";

const router: IRouter = Router();

router.use(healthRouter);
router.use(authRouter);
router.use(dashboardRouter);
router.use(walletRouter);
router.use(circlesRouter);
router.use(goalsRouter);
router.use(learnRouter);
router.use(activityRouter);
router.use(notificationsRouter);
router.use(profileRouter);
router.use(storageRouter);
router.use(passkeysRouter);

export default router;
