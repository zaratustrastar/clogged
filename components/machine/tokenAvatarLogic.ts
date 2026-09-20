/** Whether the local "this image failed to load" flag must reset given a
 *  transition from one imageUrl to another - true exactly when the URL
 *  itself has changed (including to/from null/undefined), never merely
 *  because the component re-rendered for some unrelated reason.
 *
 *  Extracted into its own plain .ts file, separate from TokenAvatar.tsx
 *  (which contains JSX) - this project's vitest config runs no JSX/React
 *  plugin (deliberately logic-only test environment; see vitest.config.mts),
 *  so a .test.ts file can never import anything from a .tsx file that
 *  actually contains JSX syntax without failing to parse. Keeping this
 *  rule here, imported by TokenAvatar.tsx rather than defined inside it,
 *  is what makes it directly unit-testable at all in this project.
 */
export function shouldResetImageFailure(
  prevImageUrl: string | null | undefined,
  currentImageUrl: string | null | undefined
): boolean {
  return (currentImageUrl ?? null) !== (prevImageUrl ?? null);
}
