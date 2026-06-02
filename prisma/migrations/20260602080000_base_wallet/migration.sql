-- DropIndex
DROP INDEX "Wallet_stellarPublicKey_key";

-- AlterTable
ALTER TABLE "Wallet" DROP COLUMN "stellarPublicKey",
DROP COLUMN "stellarSecretEnc",
DROP COLUMN "trustlineAt",
ADD COLUMN     "address" TEXT NOT NULL,
ADD COLUMN     "privateKeyEnc" TEXT NOT NULL;

-- CreateIndex
CREATE UNIQUE INDEX "Wallet_address_key" ON "Wallet"("address");

