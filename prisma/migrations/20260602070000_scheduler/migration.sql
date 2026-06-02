-- AlterTable
ALTER TABLE "CircleMember" ADD COLUMN     "remindedRound" INTEGER NOT NULL DEFAULT 0;

-- AlterTable
ALTER TABLE "Goal" ADD COLUMN     "lastAutoSaveAt" TIMESTAMP(3);

