-- AlterTable
ALTER TABLE "User" ADD COLUMN     "privyId" TEXT,
ALTER COLUMN "passwordHash" DROP NOT NULL;

-- CreateIndex
CREATE UNIQUE INDEX "User_privyId_key" ON "User"("privyId");

