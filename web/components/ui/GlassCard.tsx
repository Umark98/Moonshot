"use client";

import { cn } from "@/lib/utils";
import { motion, type HTMLMotionProps } from "framer-motion";

interface GlassCardProps extends HTMLMotionProps<"div"> {
  variant?: "default" | "hover" | "elevated" | "interactive";
  padding?: "none" | "sm" | "md" | "lg";
  glow?: boolean;
}

const paddings = {
  none: "",
  sm: "p-4",
  md: "p-6",
  lg: "p-8",
};

const variants = {
  default: "glass-card",
  hover: "glass-card-hover",
  elevated: "glass-elevated",
  interactive: "glass-card-hover cursor-pointer",
};

export function GlassCard({
  variant = "default",
  padding = "md",
  glow = false,
  className,
  children,
  ...props
}: GlassCardProps) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.4, ease: [0.16, 1, 0.3, 1] }}
      className={cn(
        variants[variant],
        paddings[padding],
        glow && "shadow-glow-sm",
        className,
      )}
      {...props}
    >
      {children}
    </motion.div>
  );
}
