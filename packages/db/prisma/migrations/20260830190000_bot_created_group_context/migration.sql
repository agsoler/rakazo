ALTER TABLE "chat_groups"
ADD COLUMN "creatorBotId" TEXT,
ADD COLUMN "creatorContext" TEXT,
ADD COLUMN "createKey" TEXT;

CREATE INDEX "chat_groups_creatorBotId_idx" ON "chat_groups"("creatorBotId");
CREATE UNIQUE INDEX "chat_groups_workspaceId_createKey_key" ON "chat_groups"("workspaceId", "createKey");

ALTER TABLE "chat_groups"
ADD CONSTRAINT "chat_groups_creatorBotId_fkey"
FOREIGN KEY ("creatorBotId") REFERENCES "bots"("id")
ON DELETE SET NULL ON UPDATE CASCADE;
