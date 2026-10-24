//! Protocol khóa User dùng chung cho invitation và mutation account/member có hai principal.

use crate::{PgUnitOfWork, storage_error};
use iot_application::error::ApplicationError;
use iot_domain::identity::SessionProof;
use uuid::Uuid;

impl PgUnitOfWork {
    /**
     * Khóa actor/subject theo UUID tăng dần trước Workspace để các mutation chéo không deadlock.
     * Input
     * Param: proof — digest session chỉ dùng tra identity hint, phải authorize lại sau khóa.
     * Param: `subject_id` — issuer hoặc target identity cần cùng User fence với actor.
     * Output: hoàn thành hoặc session/storage error; không tự cấp principal hoặc khóa Workspace.
     */
    pub(crate) async fn lock_session_subjects(
        &mut self,
        proof: &SessionProof,
        subject_id: Uuid,
    ) -> Result<(), ApplicationError> {
        // Identity session bất biến; lookup chưa cấp quyền và được current resolver đọc lại sau khóa.
        let actor_id: Uuid =
            sqlx::query_scalar("SELECT user_id FROM sessions WHERE token_digest=$1")
                .bind(proof.token_digest.as_slice())
                .fetch_optional(&mut *self.transaction)
                .await
                .map_err(storage_error)?
                .ok_or(ApplicationError::SessionInvalid)?;
        let identities = vec![actor_id, subject_id];
        // ORDER BY nằm trước LockRows; mọi giá trị bind, không nội suy UUID vào SQL.
        sqlx::query("SELECT user_id FROM users WHERE user_id=ANY($1) ORDER BY user_id FOR UPDATE")
            .bind(identities)
            .fetch_all(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        Ok(())
    }
}
